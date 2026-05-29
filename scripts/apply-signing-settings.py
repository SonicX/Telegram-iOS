#!/usr/bin/env python3
"""
Проставляет настройки подписи в сгенерированный project.pbxproj.

rules_xcodeproj в bazel-режиме (CODE_SIGNING_ALLOWED = NO) НЕ записывает
DEVELOPMENT_TEAM / CODE_SIGN_IDENTITY / PROVISIONING_PROFILE_SPECIFIER для
file-based provisioning-профилей. Эти значения нужны Xcode для UI «Signing &
Capabilities» и для архивации. Чтобы они не слетали при каждой перегенерации
проекта, этот скрипт детерминированно дописывает их обратно.

Что выставляется:
  - на уровне проекта (XCBuildConfiguration без BAZEL_LABEL, где уже стоит
    CODE_SIGN_STYLE = Manual):  DEVELOPMENT_TEAM
  - на таргете приложения (BAZEL_LABEL == target_label):
      Debug   -> dev-профиль + dev-сертификат
      Release -> dist-профиль + dist-сертификат

Значения берутся из самих .mobileprovision (Name, DeveloperCertificates[0] CN,
TeamIdentifier), поэтому какой профиль положишь — то и проставится.

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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--pbxproj', required=True)
    parser.add_argument('--target-label', default='@@//Telegram:Swiftgram')
    parser.add_argument('--dev-profile', default='build-system/codesigning-dev/profiles/Telegram.mobileprovision')
    parser.add_argument('--dist-profile', default='build-system/codesigning/profiles/Telegram_Store.mobileprovision')
    args = parser.parse_args()

    if not os.path.isfile(args.pbxproj):
        print('apply-signing: pbxproj не найден: {}'.format(args.pbxproj))
        return 1

    dev = read_profile(args.dev_profile)
    dist = read_profile(args.dist_profile) if os.path.isfile(args.dist_profile) else None
    team = dev['team']

    label_line = 'BAZEL_LABEL = "{}";'.format(args.target_label)

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
        is_target = any(label_line in k for k in keys)
        is_manual_proj = (
            any(k.strip() == 'CODE_SIGN_STYLE = Manual;' for k in keys)
            and not any('BAZEL_LABEL' in k for k in keys)
        )
        blocks.append({
            'bs_start': bs_start, 'bs_end': bs_end, 'name': name,
            'keys': keys, 'is_target': is_target, 'is_manual_proj': is_manual_proj,
        })

    indent = '\t\t\t\t'
    target_patched = 0
    proj_patched = 0

    # Применяем с конца, чтобы не сдвигать индексы верхних блоков
    for b in sorted(blocks, key=lambda x: x['bs_start'], reverse=True):
        add = []
        remove_substrings = []

        if b['is_target']:
            if b['name'] == 'Debug':
                add = [
                    '{}CODE_SIGN_IDENTITY = {};'.format(indent, pbx_quote(dev['cert'])),
                    '{}"PROVISIONING_PROFILE_SPECIFIER[sdk=iphoneos*]" = {};'.format(indent, pbx_quote(dev['name'])),
                ]
            elif b['name'] == 'Release' and dist is not None:
                add = [
                    '{}CODE_SIGN_IDENTITY = {};'.format(indent, pbx_quote(dist['cert'])),
                    '{}"PROVISIONING_PROFILE_SPECIFIER[sdk=iphoneos*]" = {};'.format(indent, pbx_quote(dist['name'])),
                ]
            else:
                continue
            # team задаётся на уровне проекта и наследуется — убираем любые
            # DEVELOPMENT_TEAM (в т.ч. [sdk=...]-варианты, которые мог дописать Xcode)
            remove_substrings = ['CODE_SIGN_IDENTITY', 'PROVISIONING_PROFILE_SPECIFIER', 'DEVELOPMENT_TEAM']
            target_patched += 1
        elif b['is_manual_proj']:
            add = ['{}DEVELOPMENT_TEAM = {};'.format(indent, pbx_quote(team))]
            remove_substrings = ['DEVELOPMENT_TEAM']
            proj_patched += 1
        else:
            continue

        filtered = [k for k in b['keys'] if not any(s in k for s in remove_substrings)]
        lines[b['bs_start'] + 1:b['bs_end']] = add + filtered

    if target_patched == 0:
        print('apply-signing: ВНИМАНИЕ — не найден таргет {} в pbxproj. '
              'Возможно, изменилась структура rules_xcodeproj.'.format(args.target_label))
        return 2

    with open(args.pbxproj, 'w') as f:
        f.write('\n'.join(lines))

    print('apply-signing: team={} | Debug={}/{} | Release={}'.format(
        team, dev['name'], dev['cert'].split(':')[0],
        '{}/{}'.format(dist['name'], dist['cert'].split(':')[0]) if dist else '(dist-профиль не найден, пропущен)'
    ))
    print('apply-signing: пропатчено блоков — таргет:{}, проект:{}'.format(target_patched, proj_patched))
    return 0


if __name__ == '__main__':
    sys.exit(main())
