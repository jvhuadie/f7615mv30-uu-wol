"""Regenerate the standalone shell installer, without downloading vendor code."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
template = (root / 'src/install-template.sh').read_text(encoding='utf-8')
control = (root / 'src/control.sh').read_text(encoding='utf-8').rstrip()
hook = (root / 'src/hook.sh').read_text(encoding='utf-8').rstrip()
logger = (root / 'src/log-writer.sh').read_text(encoding='utf-8').rstrip()
upgrade = (root / 'src/upgrade.sh').read_text(encoding='utf-8').rstrip()
marker = '__EMBED_SERVICE_SCRIPTS__'
if template.count(marker) != 1:
    raise SystemExit('Expected exactly one embedded-script marker')
embedded = (
    'write_service_scripts() {\nSERVICE_DIR=$1\n'
    'cat > "$SERVICE_DIR/control.sh" <<\'UU_CONTROL_EOF\'\n'
    + control + '\nUU_CONTROL_EOF\n'
    + 'cat > "$SERVICE_DIR/hook.sh" <<\'UU_HOOK_EOF\'\n'
    + hook + '\nUU_HOOK_EOF\n'
    + 'cat > "$SERVICE_DIR/log-writer.sh" <<\'UU_LOGGER_EOF\'\n'
    + logger + '\nUU_LOGGER_EOF\n}\n'
    + upgrade
)
if template.count('__SERVICE_FUNCTIONS__') != 1:
    raise SystemExit('Expected exactly one service-functions marker')
rendered = template.replace('__SERVICE_FUNCTIONS__', embedded).replace(marker, 'write_service_scripts "$STAGE"')
with (root / 'install.sh').open('w', encoding='utf-8', newline='\n') as out:
    out.write(rendered)
print('Generated install.sh')
