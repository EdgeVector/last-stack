"""Exercise the real pre-install guard with a pure launchctl function."""
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
DRIVER=ROOT/'skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh'
HELPERS=ROOT/'skills/lastdb-safe-upgrade/scripts/launchd-job-checks.sh'

class LaunchdPrecheckTests(unittest.TestCase):
    def run_guard(self, loaded=True, resolved=True, plist=True):
        function=re.search(r'^assert_launchd_label_usable\(\) \{.*?^\}',DRIVER.read_text(),re.M|re.S).group()
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/'primary.plist'
            if plist: path.touch()
            script='''set -euo pipefail
source "$1"
VENUE=sidebin
LAUNCHD_LABEL=com.test.primary
LAUNCHD_LABEL_RESOLVED="$3"
LAUNCHD_PLIST="$2"
log() { :; }
die() { printf '%s\\n' "$*" >&2; exit 2; }
launchctl() {
  if [ "$1" = print ]; then
    [ "$2" = "gui/$(id -u)/com.test.primary" ] || return 98
    return "$4"
  fi
  if [ "$1" = list ]; then
    printf '123 0 com.test.primary\\n'
    return 141
  fi
  return 99
}
'''
            # Capture the fake result before launchctl's positional args shadow it.
            script=script.replace('return "$4"','return '+('0' if loaded else '113'))
            result=subprocess.run(['bash','-c',script+function+'\nassert_launchd_label_usable\n','test',str(HELPERS),str(path),'1' if resolved else '0'],capture_output=True,text=True,timeout=5)
            return result
    def test_loaded_job_survives_unrelated_list_sigpipe(self):
        r=self.run_guard();self.assertEqual(r.returncode,0,r.stderr)
    def test_absent_exact_job_still_refuses(self):
        r=self.run_guard(loaded=False);self.assertNotEqual(r.returncode,0)
    def test_unresolved_label_still_refuses(self):
        self.assertNotEqual(self.run_guard(resolved=False).returncode,0)
    def test_missing_plist_still_refuses(self):
        self.assertNotEqual(self.run_guard(plist=False).returncode,0)

if __name__=='__main__': unittest.main()
