import json
import os
import shutil
import subprocess

from BuildEnvironment import is_apple_silicon, call_executable, BuildEnvironment


def remove_directory(path):
    if os.path.isdir(path):
        shutil.rmtree(path)


def run_fix_build_permissions(base_path):
    """Removes read-only flags Bazel sets on its outputs.

    Run before regenerating the Xcode project so the bazel-out tree and
    any existing DerivedData can be overwritten without "Permission denied"
    errors.  The same script is wired in as a pre-build run script of the
    generated `BazelDependencies` target (via `pre_build` on the `xcodeproj`
    rule in `Telegram/BUILD`), so it also fires on every Xcode build.
    """
    script = os.path.join(base_path, 'scripts', 'fix-build-permissions.sh')
    if not os.path.isfile(script):
        return
    try:
        subprocess.call(['sh', script])
    except Exception as exception:  # noqa: BLE001 - best-effort, never fail generation
        print('fix-build-permissions: skipped due to {}'.format(exception))


def apply_signing_settings(base_path, xcodeproj_path, target_name):
    """Проставляет настройки подписи в project.pbxproj через scripts/apply-signing-settings.py.

    Применяется только к основному приложению (target_name == 'Telegram', проект Swiftgram).
    Best-effort: если скрипт отсутствует или падает — генерация не прерывается.
    """
    if target_name != 'Telegram':
        return
    script = os.path.join(base_path, 'scripts', 'apply-signing-settings.py')
    if not os.path.isfile(script):
        return
    pbxproj = os.path.join(base_path, xcodeproj_path, 'project.pbxproj')
    if not os.path.isfile(pbxproj):
        print('apply-signing: project.pbxproj не найден ({}), пропуск'.format(pbxproj))
        return
    try:
        subprocess.call(['python3', script, '--pbxproj', pbxproj])
    except Exception as exception:  # noqa: BLE001 - не валим генерацию из-за подписи
        print('apply-signing: пропущено из-за {}'.format(exception))


def generate_xcodeproj(build_environment: BuildEnvironment, disable_extensions, disable_provisioning_profiles, include_release, generate_dsym, bazel_app_arguments, target_name):
    run_fix_build_permissions(build_environment.base_path)

    if '/' in target_name:
        app_target_spec = target_name.split('/')[0] + '/' + target_name.split('/')[1] + ':' + target_name.split('/')[1]
        app_target = target_name
        app_target_clean = app_target.replace('/', '_')
    else:
        app_target_spec = '{target}:{target}'.format(target=target_name)
        app_target = target_name
        app_target_clean = app_target.replace('/', '_')

    bazel_generate_arguments = [build_environment.bazel_path]

    bazel_generate_arguments += ['run', '//{}_xcodeproj'.format(app_target_spec)]

    if target_name == 'Telegram':
        if disable_extensions:
            bazel_generate_arguments += ['--//{}:disableExtensions'.format(app_target)]
        bazel_generate_arguments += ['--//{}:disableStripping'.format(app_target)]

    project_bazel_arguments = []
    for argument in bazel_app_arguments:
        project_bazel_arguments.append(argument)

    if target_name == "Swiftgram/Playground":
        project_bazel_arguments += ["--swiftcopt=-no-warnings-as-errors", "--copt=-Wno-error"]#, "--swiftcopt=-DSWIFTGRAM_PLAYGROUND", "--copt=-DSWIFTGRAM_PLAYGROUND=1"]

    if target_name == 'Telegram':
        if disable_extensions:
            project_bazel_arguments += ['--//{}:disableExtensions'.format(app_target)]
        project_bazel_arguments += ['--//{}:disableStripping'.format(app_target)]

    project_bazel_arguments += ['--features=-swift.debug_prefix_map']
    
    xcodeproj_bazelrc = os.path.join(build_environment.base_path, 'xcodeproj.bazelrc')
    if os.path.isfile(xcodeproj_bazelrc):
        os.unlink(xcodeproj_bazelrc)
    with open(xcodeproj_bazelrc, 'w') as file:
        for argument in project_bazel_arguments:
            file.write('build ' + argument + '\n')

    call_executable(bazel_generate_arguments)
    if app_target_spec == "Telegram:Telegram": # MARK: Swiftgram
        app_target_spec = "Telegram/Swiftgram"
    xcodeproj_path = '{}.xcodeproj'.format(app_target_spec.replace(':', '/'))

    # MARK: Swiftgram — фиксируем настройки подписи в сгенерированном проекте.
    # rules_xcodeproj в bazel-режиме не пишет DEVELOPMENT_TEAM / CODE_SIGN_IDENTITY /
    # PROVISIONING_PROFILE_SPECIFIER для file-based профилей, поэтому проставляем их
    # сами (значения берутся из .mobileprovision). Делается ДО открытия Xcode, чтобы
    # подпись «вставала на место» при каждой перегенерации без ручных правок.
    apply_signing_settings(build_environment.base_path, xcodeproj_path, target_name)

    return xcodeproj_path


def generate(build_environment: BuildEnvironment, disable_extensions, disable_provisioning_profiles, include_release, generate_dsym, bazel_app_arguments, target_name) -> str:
    return generate_xcodeproj(build_environment, disable_extensions, disable_provisioning_profiles, include_release, generate_dsym, bazel_app_arguments, target_name)
