"""Known pre-identity desktop-file format for backward-compatibility fixtures."""

def value(text):
    return text.replace('\\', '\\\\').replace('\n', '\\n').replace('\r', '\\r').replace('\t', '\\t')


def argument(text):
    escaped = ''.join('\\' + char if char in '\\"$`' else '%%' if char == '%' else char for char in str(text))
    return value('"' + escaped + '"')


def contents(name, launcher, arguments=(), files=False):
    command = ['/bin/sh', '-c', 'exec "$@"', 'whisky-desktop', str(launcher), *map(str, arguments)]
    execution = ' '.join(map(argument, command)) + (' %f' if files else '')
    types = 'application/x-ms-dos-executable;application/x-msdownload;application/x-msi;application/vnd.microsoft.portable-executable;'
    return ('[Desktop Entry]\nVersion=1.0\nType=Application\nName=' + value(name) + '\nExec=' + execution +
            '\nIcon=applications-games\nTerminal=false\nStartupNotify=false\nCategories=Game;\nX-Whisky-Managed=true\n' +
            'X-Whisky-Launcher=' + value(str(launcher)) + '\n' + ('MimeType=' + types if files else '') + '\n')
