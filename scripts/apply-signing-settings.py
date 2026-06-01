#!/usr/bin/env python3
"""
Проставляет настройки подписи в сгенерированный project.pbxproj.

rules_xcodeproj в bazel-режиме (CODE_SIGNING_ALLOWED = NO) НЕ записывает
DEVELOPMENT_TEAM / CODE_SIGN_IDENTITY / PROVISIONING_PROFILE_SPECIFIER для
file-based provisioning-профилей. Эти значения нужны Xcode для UI «Signing &
Capabilities» и для архивации. Чтобы они не слетали при каждой перегенерации
проекта, этот скрипт детерминированно дописывает их обратно.

Модель подписи (как настроено вручную в Xcode):
  - СЕРТИФИКАТ и TEAM задаются ОДИН раз на уровне проекта
    (XCBuildConfiguration без BAZEL_LABEL, где стоит CODE_SIGN_STYLE = Manual):
      Debug   -> CODE_SIGN_IDENTITY = dev-сертификат  + DEVELOPMENT_TEAM
      Release -> CODE_SIGN_IDENTITY = dist-сертификат + DEVELOPMENT_TEAM
    Все таргеты НАСЛЕДУЮТ их от проекта.
  - на КАЖДОМ подписываемом таргете (BAZEL_LABEL из таблицы TARGETS) ставится
    ТОЛЬКО PROVISIONING_PROFILE_SPECIFIER (свой профиль на Debug/Release),
    без identity и без team — они приходят с уровня проекта.

Сертификат на уровне проекта одинаков для всех таргетов, поэтому берётся из
профилей основного приложения (первый таргет в TARGETS). Имена профилей и CN
сертификатов читаются из самих .mobileprovision — что положишь, то и встанет.

Идемпотентен: повторный запуск не плодит дубли.
"""

import argparse
import os
import plistlib
import re
import subprocess
import sys


def read_profile(path):
    data = subprocess.run(
        ['security', 'cms', '-D', '-i', path],
        capture_output=True, check=True
    ).stdout
    d = plistlib.loads(data)
    name = d['Name']
    team = d['TeamIdentifier'][0]
    cert_der = d['DeveloperCertificates'][0]
    subject = subprocess.run(
        ['openssl', 'x509', '-inform', 'DER', '-noout', '-subject', '-nameopt', 'RFC2253'],
        input=cert_der, capture_output=True, check=True
    ).stdout.decode('utf-8', 'replace')
    m = re.search(r'CN=([^,]+)', subject)
    if not m:
        raise RuntimeError('Не удалось извлечь CN сертификата из {}'.format(path))
    cert_cn = m.group(1).strip()
    return {'name': name, 'team': team, 'cert': cert_cn}


def pbx_quote(value):
    # В pbxproj без кавычек допустимы только простые токены
    if re.fullmatch(r'[A-Za-z0-9_.]+', value):
        return value
    escaped = value.replace('\\', '\\\\').replace('"', '\\"')
    return '"{}"'.format(escaped)


# Таблица таргетов, которым нужно проставить подпись. Каждый таргет
# идентифицируется своим bazel-label (значение BAZEL_LABEL в его
# XCBuildConfiguration) и имеет собственную пару dev/dist профилей.
#
# Чтобы добавить новый подписываемый таргет (расширение / watch-app):
# допиши сюда строку с его label и путями к профилям — никакой другой
# код менять не нужно.
TARGETS = [
    {
        'label': '@@//Telegram:Swiftgram',
        'dev_profile': 'build-system/codesigning-dev/profiles/Telegram.mobileprovision',
        'dist_profile': 'build-system/codesigning/profiles/Telegram_Store.mobileprovision',
    },
    {
        # Расширение уведомлений. Без явной подписи Xcode при каждой
        # перегенерации сбрасывал профиль этого таргета, и архив падал /
        # пуши не работали.
        'label': '@@//Telegram:NotificationServiceExtensionv1',
        'dev_profile': 'build-system/codesigning-dev/profiles/TelegramNotification.mobileprovision',
        'dist_profile': 'build-system/codesigning/profiles/TelegramNotification_Store.mobileprovision',
    },
]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--pbxproj', required=True)
    args = parser.parse_args()

    if not os.path.isfile(args.pbxproj):
        print('apply-signing: pbxproj не найден: {}'.format(args.pbxproj))
        return 1

    # Загружаем профили каждого таргета; пропускаем отсутствующие.
    resolved_targets = []
    team = None
    for target in TARGETS:
        if not os.path.isfile(target['dev_profile']):
            print('apply-signing: dev-профиль не найден для {}, таргет пропущен: {}'.format(
                target['label'], target['dev_profile']))
            continue
        dev = read_profile(target['dev_profile'])
        dist = read_profile(target['dist_profile']) if os.path.isfile(target['dist_profile']) else None
        if team is None:
            team = dev['team']
        resolved_targets.append({
            'label_line': 'BAZEL_LABEL = "{}";'.format(target['label']),
            'label': target['label'],
            'dev': dev,
            'dist': dist,
        })

    if not resolved_targets:
        print('apply-signing: ни одного профиля не найдено, нечего проставлять')
        return 2

    with open(args.pbxproj, 'r') as f:
        lines = f.read().split('\n')

    # Найти все XCBuildConfiguration блоки
    blocks = []
    for i, line in enumerate(lines):
        if line.strip() != 'isa = XCBuildConfiguration;':
            continue
        bs_start = i + 1
        if lines[bs_start].strip() != 'buildSettings = {':
            continue
        j = bs_start + 1
        while j < len(lines) and lines[j].strip() != '};':
            j += 1
        bs_end = j  # строка '};', закрывающая buildSettings
        name = None
        if bs_end + 1 < len(lines):
            mm = re.match(r'\s*name = (.+);\s*$', lines[bs_end + 1])
            if mm:
                name = mm.group(1).strip().strip('"')
        keys = lines[bs_start + 1:bs_end]
        # Какому из настраиваемых таргетов принадлежит блок (по BAZEL_LABEL)?
        matched_target = None
        for rt in resolved_targets:
            if any(rt['label_line'] in k for k in keys):
                matched_target = rt
                break
        is_manual_proj = (
            any(k.strip() == 'CODE_SIGN_STYLE = Manual;' for k in keys)
            and not any('BAZEL_LABEL' in k for k in keys)
        )
        blocks.append({
            'bs_start': bs_start, 'bs_end': bs_end, 'name': name,
            'keys': keys, 'matched_target': matched_target, 'is_manual_proj': is_manual_proj,
        })

    indent = '\t\t\t\t'
    target_patched = {}
    proj_patched = 0

    # Сертификат на уровне проекта берём из профилей основного приложения
    # (первый таргет). Он общий для всех таргетов — они наследуют его.
    project_certs = resolved_targets[0]

    # Применяем с конца, чтобы не сдвигать индексы верхних блоков
    for b in sorted(blocks, key=lambda x: x['bs_start'], reverse=True):
        add = []
        remove_substrings = []

        rt = b['matched_target']
        if rt is not None:
            # На таргете — ТОЛЬКО профиль. Сертификат и team наследуются от
            # проекта, поэтому здесь их не ставим (и вычищаем, если Xcode
            # успел их дописать на таргет).
            dev = rt['dev']
            dist = rt['dist']
            if b['name'] == 'Debug':
                add = [
                    '{}"PROVISIONING_PROFILE_SPECIFIER[sdk=iphoneos*]" = {};'.format(indent, pbx_quote(dev['name'])),
                ]
            elif b['name'] == 'Release' and dist is not None:
                add = [
                    '{}"PROVISIONING_PROFILE_SPECIFIER[sdk=iphoneos*]" = {};'.format(indent, pbx_quote(dist['name'])),
                ]
            else:
                continue
            remove_substrings = ['CODE_SIGN_IDENTITY', 'PROVISIONING_PROFILE_SPECIFIER', 'DEVELOPMENT_TEAM']
            target_patched[rt['label']] = target_patched.get(rt['label'], 0) + 1
        elif b['is_manual_proj']:
            # На уровне проекта — сертификат (Debug=dev / Release=dist) + team.
            # Профиль здесь НЕ ставим: он индивидуален для каждого таргета.
            if b['name'] == 'Debug':
                add = [
                    '{}CODE_SIGN_IDENTITY = {};'.format(indent, pbx_quote(project_certs['dev']['cert'])),
                    '{}DEVELOPMENT_TEAM = {};'.format(indent, pbx_quote(team)),
                ]
            elif b['name'] == 'Release' and project_certs['dist'] is not None:
                add = [
                    '{}CODE_SIGN_IDENTITY = {};'.format(indent, pbx_quote(project_certs['dist']['cert'])),
                    '{}DEVELOPMENT_TEAM = {};'.format(indent, pbx_quote(team)),
                ]
            else:
                # Конфигурация без known-имени — оставляем team, как было.
                add = ['{}DEVELOPMENT_TEAM = {};'.format(indent, pbx_quote(team))]
            remove_substrings = ['CODE_SIGN_IDENTITY', 'DEVELOPMENT_TEAM']
            proj_patched += 1
        else:
            continue

        filtered = [k for k in b['keys'] if not any(s in k for s in remove_substrings)]
        lines[b['bs_start'] + 1:b['bs_end']] = add + filtered

    if not target_patched.get('@@//Telegram:Swiftgram', 0):
        print('apply-signing: ВНИМАНИЕ — не найден основной таргет @@//Telegram:Swiftgram в pbxproj. '
              'Возможно, изменилась структура rules_xcodeproj.')
        return 2

    with open(args.pbxproj, 'w') as f:
        f.write('\n'.join(lines))

    # На уровне проекта: сертификаты + team (наследуются таргетами).
    print('apply-signing: ПРОЕКТ team={} | Debug-cert={} | Release-cert={} | блоков={}'.format(
        team,
        project_certs['dev']['cert'].split(':')[0],
        project_certs['dist']['cert'].split(':')[0] if project_certs['dist'] else '(нет dist)',
        proj_patched,
    ))
    # На таргетах: только профили.
    for rt in resolved_targets:
        count = target_patched.get(rt['label'], 0)
        dev = rt['dev']
        dist = rt['dist']
        print('apply-signing: ТАРГЕТ {} | блоков={} | профиль Debug={} | профиль Release={}'.format(
            rt['label'], count,
            dev['name'],
            dist['name'] if dist else '(dist-профиль не найден)',
        ))
    return 0


if __name__ == '__main__':
    sys.exit(main())
