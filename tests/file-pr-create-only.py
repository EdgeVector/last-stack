#!/usr/bin/env python3
"""Public filing flags with a private decision gate and Card CLI only."""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRIEF = 'Repo: EdgeVector/loom\nDifficulty: hard\n\n## GOAL\nCount exact active executions.\n\n## END STATE\nThe canonical active count matches.\n'

def check(value, message):
    if not value: raise AssertionError(message)

def fixture(flags, mode='ok'):
    home = Path(tempfile.mkdtemp(prefix='file-pr-create-only-')); artifact = home / 'artifact'; binary = artifact / 'bin'
    binary.mkdir(parents=True); shutil.copy2(ROOT / 'bin/last-stack-kanban-file-pr', binary / 'last-stack-kanban-file-pr')
    log = home / 'calls.jsonl'
    common = '#!/usr/bin/env python3\nimport json,os,sys\nfrom pathlib import Path\nwith Path(os.environ["PRIVATE_CALLS"]).open("a") as out:out.write(json.dumps([Path(sys.argv[0]).name,sys.argv[1:]])+"\\n")\n'
    admission = common + 'sys.exit(0)\n'
    decision = common + 'body=sys.stdin.read()\nif os.environ["PRIVATE_MODE"]=="conflict":sys.stderr.write("private settled decision conflict\\n");sys.exit(2)\nprint(body+"\\n## DECISION-CHECK\\ndate: 2026-10-09T00:00:00Z\\nverdict: honor\\nbackend: brain\\nslugs: decision-private")\n'
    kanban = common + 'a=sys.argv[1:]\nif a[:2]==["milestone","show"]:print(json.dumps({"state":"active","north_star":"ns-private"}));sys.exit(0)\nif a[0]!="add":sys.exit(99)\nbody=sys.stdin.read();Path(os.environ["PRIVATE_BODY"]).write_text(body)\nif "--json" in a:print(json.dumps({"version":1,"result":"error" if os.environ["PRIVATE_MODE"]=="board-error" else "created","durability":"durable"}))\nelse:print("private board receipt")\nsys.exit(9 if os.environ["PRIVATE_MODE"]=="board-error" else 0)\n'
    for name, source in [('last-stack-feature-portfolio-admission', admission), ('last-stack-kanban-decision-check', decision), ('kanban', kanban)]:
        path = binary / name; path.write_text(source); path.chmod(0o755)
    environment = {**os.environ, 'HOME': str(home), 'PRIVATE_CALLS': str(log), 'PRIVATE_MODE': mode, 'PRIVATE_BODY': str(home / 'body.md')}
    argv = ['bash', str(binary / 'last-stack-kanban-file-pr'), 'factory-private', '--title', 'Private count', '--repo', 'EdgeVector/loom',
            '--north-star', 'ns-private', '--milestone', 'ms-private', '--column', 'backlog', '--work-class', 'repair',
            '--difficulty', 'hard', '--no-derive-surfaces', '--board-cli', str(binary / 'kanban'), *flags]
    result = subprocess.run(argv, input=BRIEF.encode(), capture_output=True, env=environment, timeout=8)
    calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
    return result, calls, home

def forwarding():
    result, calls, home = fixture(['--create-only', '--json'])
    check(result.returncode == 0, 'public file-pr create-only JSON flags refused')
    adds = [args for name, args in calls if name == 'kanban' and args[0] == 'add']
    check(len(adds) == 1 and adds[0].count('--create-only') == 1 and adds[0].count('--json') == 1, 'file-pr did not forward exact creation flags once')
    try: value = json.loads(result.stdout)
    except ValueError as error: raise AssertionError('JSON result contains trailing filed text or changed Card receipt') from error
    check(value == {'version': 1, 'result': 'created', 'durability': 'durable'}, 'JSON result contains trailing filed text or changed Card receipt')
    names = [name for name, args in calls]
    check(names.index('last-stack-kanban-decision-check') < names.index('kanban') and 'verdict: honor' in (home / 'body.md').read_text(), 'create-only bypassed or replaced the decision gate')

def ordinary():
    result, calls, home = fixture([])
    check(result.returncode == 0 and b'filed factory-private column=backlog' in result.stdout, 'ordinary filing text changed')
    add = next(args for name, args in calls if name == 'kanban' and args[0] == 'add')
    check('--create-only' not in add and '--json' not in add, 'ordinary argv gained creation flags')

def conflict():
    result, calls, home = fixture(['--create-only', '--json'], 'conflict')
    check(result.returncode == 2 and not result.stdout and not any(name == 'kanban' for name, args in calls), 'create-only reached a Card effect after a decision conflict')

def board_error():
    result, calls, home = fixture(['--create-only', '--json'], 'board-error')
    check(result.returncode == 1 and json.loads(result.stdout)['result'] == 'error' and b'kanban add failed' in result.stderr,
          'public creation refusal lost its typed JSON or exit status')

def invalid(flags, message):
    result, calls, home = fixture(flags)
    check(result.returncode == 2 and not result.stdout and not calls, message)

CASES = {'forwarding': forwarding, 'ordinary': ordinary, 'conflict': conflict, 'board_error': board_error,
    'todo': lambda: invalid(['--create-only', '--column', 'todo'], 'create-only allowed todo'),
    'skip_decision': lambda: invalid(['--create-only', '--skip-decision-check'], 'create-only bypassed the decision gate'),
    'ensure_milestone': lambda: invalid(['--create-only', '--ensure-milestone'], 'create-only allowed an extra milestone mutation'),
    'json_dry': lambda: invalid(['--json', '--dry-run'], 'JSON mode returned a text-only dry result')}
if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('case', nargs='?', choices=CASES); args = parser.parse_args()
    for name in ([args.case] if args.case else CASES):
        try: CASES[name]()
        except Exception as error: print('FAIL: ' + name + ': ' + str(error), file=sys.stderr); sys.exit(1)
        print('PASS: ' + name)
