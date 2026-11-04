"""Unit tests of github-app.py: no network, no gh, no GitHub account (gh, HTTP and the browser are replaced).

Run: python3 -I -B -m unittest discover -s github/scripts -p '*_test.py' (make github-app-test).
"""
import base64
import contextlib
import importlib.util
import io
import json
import os
import pathlib
import subprocess
import tempfile
import unittest
import urllib.request
from unittest import mock

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("github_app", HERE / "github-app.py")
ga = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ga)

PEM = "-----BEGIN RSA PRIVATE KEY-----\nMIIfake\n-----END RSA PRIVATE KEY-----\n"


def gh_result(stdout="", code=0):
    return subprocess.CompletedProcess(["gh"], code, stdout=stdout, stderr="" if code == 0 else "HTTP 404")


class TempDirs(unittest.TestCase):
    """GITHUB, KEYS and WORKSPACE of the module point into a temporary folder for each test."""

    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        (self.tmp / "infra" / "github").mkdir(parents=True)
        (self.tmp / "backend").mkdir()
        for name, value in (("GITHUB", self.tmp / "infra" / "github"), ("KEYS", self.tmp / "infra" / "github" / ".keys"),
                            ("WORKSPACE", self.tmp)):
            patcher = mock.patch.object(ga, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def tearDown(self):
        subprocess.run(["rm", "-rf", str(self.tmp)], check=True)


class DotenvAndTfvars(TempDirs):
    def test_set_dotenv_replaces_own_lines_keeps_others_and_mode_600(self):
        env = self.tmp / "backend" / ".env"
        env.write_text("A=1\nP_APP_ID=old\nB=2\n")
        ga.set_dotenv(env, "P", {"APP_ID": "7", "PRIVATE_KEY_B64": "eA=="})
        self.assertEqual(env.read_text(), "A=1\nB=2\nP_APP_ID=7\nP_PRIVATE_KEY_B64=eA==\n")
        self.assertEqual(env.stat().st_mode & 0o777, 0o600)

    def test_set_dotenv_creates_the_file(self):
        env = self.tmp / "backend" / ".env"
        ga.set_dotenv(env, "P", {"INSTALLATION_ID": "9"})
        self.assertEqual(env.read_text(), "P_INSTALLATION_ID=9\n")

    def test_set_tfvar_replaces_only_its_variable(self):
        tfvars = ga.GITHUB / "github.auto.tfvars"
        tfvars.write_text('a_client_id = "old"\nb_client_id = "keep"\n')
        with contextlib.redirect_stdout(io.StringIO()):
            ga.set_tfvar("a_client_id", "Iv1.new")
        self.assertEqual(tfvars.read_text(), 'b_client_id = "keep"\na_client_id = "Iv1.new"\n')


class WriteKey(TempDirs):
    DEST = {"type": "environment-secret", "repo": "svp-backend", "environment": "promote", "name": "KEY"}

    def test_environment_secret_goes_through_stdin_of_gh(self):
        calls = []

        def run(args, **kw):
            calls.append((args, kw.get("input")))
            return gh_result()

        with mock.patch.object(ga.subprocess, "run", run), contextlib.redirect_stdout(io.StringIO()):
            ga.write_key(self.DEST, PEM, app="a", key="stg")
        secret = [c for c in calls if c[0][:3] == ["gh", "secret", "set"]]
        self.assertEqual(len(secret), 1)
        self.assertEqual(secret[0][0], ["gh", "secret", "set", "KEY", "--env", "promote", "--repo", "anhnvcoder/svp-backend"])
        self.assertEqual(secret[0][1], PEM)
        self.assertNotIn(PEM, " ".join(secret[0][0]))

    def test_missing_environment_keeps_the_key_in_a_600_file(self):
        def run(args, **kw):
            return gh_result(code=1) if args[:2] == ["gh", "api"] else self.fail(f"unexpected {args}")

        out = io.StringIO()
        with mock.patch.object(ga.subprocess, "run", run), contextlib.redirect_stdout(out):
            ga.write_key(self.DEST, PEM, app="a", key="stg")
        held = ga.KEYS / "a-stg.pem"
        self.assertEqual(held.read_text(), PEM)
        self.assertEqual(held.stat().st_mode & 0o777, 0o600)
        self.assertIn("make github-app-key APP=a KEY=stg", out.getvalue())
        self.assertNotIn("MIIfake", out.getvalue())

    def test_dotenv_destination_writes_base64_and_app_id(self):
        dest = {"type": "dotenv", "file": "backend/.env", "prefix": "P"}
        with contextlib.redirect_stdout(io.StringIO()) as out:
            ga.write_key(dest, PEM, app_id=42)
        lines = dict(line.split("=", 1) for line in (self.tmp / "backend" / ".env").read_text().splitlines())
        self.assertEqual(lines["P_APP_ID"], "42")
        self.assertEqual(base64.b64decode(lines["P_PRIVATE_KEY_B64"]).decode(), PEM)
        self.assertNotIn("MIIfake", out.getvalue())


class SetKey(TempDirs):
    def pem_file(self, text=PEM):
        path = self.tmp / "k.pem"
        path.write_text(text)
        return path

    def test_rejects_a_file_that_is_not_a_private_key(self):
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            ga.set_key("svp-gitops-promoter", "prd", str(self.pem_file("not a key")))

    def test_rejects_an_unknown_key_name(self):
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            ga.set_key("svp-web-promoter", "prd", str(self.pem_file()))

    def test_refuses_when_the_environment_is_missing_and_keeps_the_file(self):
        path = self.pem_file()
        with mock.patch.object(ga.subprocess, "run", lambda *a, **k: gh_result(code=1)), self.assertRaises(SystemExit), \
                contextlib.redirect_stderr(io.StringIO()):
            ga.set_key("svp-gitops-promoter", "prd", str(path))
        self.assertTrue(path.exists())

    def test_writes_the_secret_then_deletes_the_file(self):
        path, calls = self.pem_file(), []

        def run(args, **kw):
            calls.append(args)
            return gh_result()

        with mock.patch.object(ga.subprocess, "run", run), contextlib.redirect_stdout(io.StringIO()):
            ga.set_key("svp-gitops-promoter", "prd", str(path))
        self.assertIn(["gh", "secret", "set", "SVP_GITOPS_APP_PRIVATE_KEY", "--env", "promote-prd", "--repo",
                       "anhnvcoder/svp-backend"], calls)
        self.assertFalse(path.exists())


class Jwt(unittest.TestCase):
    def test_signature_verifies_with_the_public_key(self):
        with tempfile.TemporaryDirectory() as tmp:
            key, pub = pathlib.Path(tmp, "k.pem"), pathlib.Path(tmp, "p.pem")
            subprocess.run(["openssl", "genrsa", "-out", str(key), "2048"], check=True, capture_output=True)
            subprocess.run(["openssl", "rsa", "-in", str(key), "-pubout", "-out", str(pub)], check=True, capture_output=True)
            token = ga.app_jwt(123, key.read_text())
            head, payload, sig = token.split(".")
            pad = lambda s: s + "=" * (-len(s) % 4)  # noqa: E731
            self.assertEqual(json.loads(base64.urlsafe_b64decode(pad(head))), {"alg": "RS256", "typ": "JWT"})
            claims = json.loads(base64.urlsafe_b64decode(pad(payload)))
            self.assertEqual(claims["iss"], "123")
            self.assertEqual(claims["exp"] - claims["iat"], 600)  # GitHub's maximum lifetime is 10 minutes
            sigfile = pathlib.Path(tmp, "s")
            sigfile.write_bytes(base64.urlsafe_b64decode(pad(sig)))
            check = subprocess.run(["openssl", "dgst", "-sha256", "-verify", str(pub), "-signature", str(sigfile)],
                                   input=f"{head}.{payload}".encode(), capture_output=True)
            self.assertEqual(check.returncode, 0, check.stdout + check.stderr)
            self.assertEqual(sorted(os.listdir(tmp)), ["k.pem", "p.pem", "s"])  # app_jwt left no key file behind


class Server(unittest.TestCase):
    def setUp(self):
        self.srv = ga.ManifestServer({"name": "x", "public": False})
        self.addCleanup(self.srv.close)

    def get(self, path):
        try:
            with urllib.request.urlopen(self.srv.url + path, timeout=5) as resp:
                return resp.status, resp.read().decode()
        except urllib.error.HTTPError as err:
            err.close()
            return err.code, ""

    def test_root_posts_the_manifest_with_state_and_loopback_redirect(self):
        status, page = self.get("")
        self.assertEqual(status, 200)
        self.assertIn(f"https://github.com/settings/apps/new?state={self.srv.state}", page)
        self.assertIn(f'"redirect_url": "{self.srv.url}callback"', page.replace("&quot;", '"'))

    def test_callback_with_a_wrong_state_is_refused(self):
        self.assertEqual(self.get("callback?state=wrong&code=c1")[0], 404)
        self.assertIsNone(self.srv.code)

    def test_callback_with_the_state_takes_the_code(self):
        self.assertEqual(self.get(f"callback?state={self.srv.state}&code=c1")[0], 200)
        self.assertEqual(self.srv.code, "c1")


class Create(TempDirs):
    CONVERSION = {"id": 7, "slug": "svp-web-promoter", "client_id": "Iv1.abc", "pem": PEM}

    def run_create(self, repos):
        calls = []

        def run(args, **kw):
            calls.append(args)
            return gh_result()

        def http_json(method, url, token=None, body=None):
            self.assertEqual((method, url), ("POST", f"{ga.API}/app-manifests/code1/conversions"))
            return self.CONVERSION

        with mock.patch.object(ga.subprocess, "run", run), mock.patch.object(ga, "http_json", http_json), \
                mock.patch.object(ga, "installed_repositories", return_value=(99, repos)), \
                mock.patch.object(ga.webbrowser, "open"), mock.patch("builtins.input", return_value=""), \
                contextlib.redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(io.StringIO()):
            ga.create("svp-web-promoter", code="code1")
        return calls, out.getvalue()

    def test_writes_key_and_client_id_and_accepts_the_right_installation(self):
        calls, out = self.run_create(["svp-gitops"])
        self.assertIn(["gh", "secret", "set", "SVP_WEB_APP_PRIVATE_KEY", "--env", "promote", "--repo", "anhnvcoder/svp-frontend"],
                      calls)
        self.assertIn('svp_web_app_client_id = "Iv1.abc"', (ga.GITHUB / "github.auto.tfvars").read_text())
        self.assertIn("covers exactly svp-gitops", out)
        self.assertNotIn("MIIfake", out)

    def test_an_installation_on_other_repositories_fails(self):
        with self.assertRaises(SystemExit):
            self.run_create(["svp-backend", "svp-gitops"])


class Check(unittest.TestCase):
    def run_check(self, override=None):
        answers = {
            ".enabled": "true", ".approval_policy": "all_external_contributors", ".default_branch": "main",
            ".security_and_analysis.dependabot_security_updates.status": "disabled", ".[].id": "1", ".state": "configured",
        }
        answers.update(override or {})

        def run(args, **kw):
            jq = args[args.index("--jq") + 1]
            if jq.startswith("[.rules"):
                return gh_result("true\n")
            if jq == ".secrets[].name":
                return gh_result("SVP_GITOPS_APP_PRIVATE_KEY\nSVP_WEB_APP_PRIVATE_KEY\n")
            return gh_result(answers[jq] + "\n")

        public = mock.MagicMock()
        public.__enter__.return_value.read.return_value = b'{"token":"t"}'
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(ga, "WORKSPACE", pathlib.Path(tmp)), \
                mock.patch.object(ga.subprocess, "run", run), mock.patch.object(ga.urllib.request, "urlopen", return_value=public), \
                contextlib.redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(io.StringIO()) as err:
            backend = pathlib.Path(tmp, "backend")
            backend.mkdir()
            (backend / ".env").write_text("".join(f"SVP_ARGOCD_NOTIFY_{k}=x\n" for k in ("APP_ID", "INSTALLATION_ID", "PRIVATE_KEY_B64")))
            try:
                ga.check(with_app_keys=False)
                code = 0
            except SystemExit as exc:
                code = exc.code
        return code, out.getvalue() + err.getvalue()

    def test_every_setting_matching_passes(self):
        code, out = self.run_check()
        self.assertEqual(code, 0, out)
        self.assertIn("every setting matches", out)
        self.assertNotIn("x\n", out)  # values of .env are never printed

    def test_private_vulnerability_reporting_off_fails(self):
        code, out = self.run_check({".enabled": "false"})
        self.assertEqual(code, 1)
        self.assertIn("private vulnerability reporting: false (want true)", out)


class Config(unittest.TestCase):
    def test_selftest_passes_on_the_committed_files(self):
        with contextlib.redirect_stdout(io.StringIO()):
            ga.selftest()


if __name__ == "__main__":
    unittest.main()
