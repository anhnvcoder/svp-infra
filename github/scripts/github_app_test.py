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
    def run_check(self, override=None, with_app_keys=False):
        answers = {
            ".enabled": "true", ".approval_policy": "all_external_contributors", ".default_branch": "main",
            ".security_and_analysis.dependabot_security_updates.status": "disabled", ".[].id": "1", ".state": "configured",
            ".value": "[]", "plan secrets": "", "repo secrets": "INFRACOST_API_KEY\n",
        }
        answers.update(override or {})

        def run(args, **kw):
            jq = args[args.index("--jq") + 1]
            if jq.startswith("[.rules"):
                return gh_result("true\n")
            if jq == ".secrets[].name" and "/environments/terraform-plan/" in args[2]:
                return gh_result(answers["plan secrets"])
            if jq == ".secrets[].name" and args[2].endswith("/svp-infra/actions/secrets"):
                return gh_result(answers["repo secrets"])
            if jq == ".secrets[].name":
                return gh_result("SVP_GITOPS_APP_PRIVATE_KEY\nSVP_WEB_APP_PRIVATE_KEY\nSVP_RELEASE_APP_PRIVATE_KEY\n")
            if answers[jq] is None:
                return gh_result(code=1)
            return gh_result(answers[jq] + "\n")

        public = mock.MagicMock()
        public.__enter__.return_value.read.return_value = b'{"token":"t"}'
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(ga, "WORKSPACE", pathlib.Path(tmp)), \
                mock.patch.object(ga.subprocess, "run", run), mock.patch.object(ga.urllib.request, "urlopen", return_value=public), \
                contextlib.redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(io.StringIO()) as err:
            backend = pathlib.Path(tmp, "backend")
            backend.mkdir()
            (backend / ".env").write_text("SVP_ARGOCD_NOTIFY_APP_ID=x\nSVP_ARGOCD_NOTIFY_INSTALLATION_ID=x\n"
                                          f"SVP_ARGOCD_NOTIFY_PRIVATE_KEY_B64={base64.b64encode(PEM.encode()).decode()}\n")
            try:
                ga.check(with_app_keys=with_app_keys)
                code = 0
            except SystemExit as exc:
                code = exc.code
        return code, out.getvalue() + err.getvalue()

    def test_every_setting_matching_passes(self):
        code, out = self.run_check()
        self.assertEqual(code, 0, out)
        self.assertIn("every setting matches", out)
        self.assertNotIn("x\n", out)  # values of .env are never printed

    def test_default_check_never_reads_the_local_key_file(self):
        real_open = pathlib.Path.read_text
        touched = []

        def guard(path, *a, **k):
            if path.name == ".env":
                touched.append(path)
            return real_open(path, *a, **k)

        with mock.patch.object(pathlib.Path, "read_text", guard):
            code, out = self.run_check()
        self.assertEqual(code, 0, out)
        self.assertEqual(touched, [])
        self.assertIn("skip  svp-argocd-notifier key in backend/.env", out)

    def test_with_app_keys_checks_the_local_variables_and_installation(self):
        with mock.patch.object(ga, "installed_repositories", return_value=(7, ["svp-gitops"])):
            code, out = self.run_check(with_app_keys=True)
        self.assertEqual(code, 1, out)  # INSTALLATION_ID=x in the fixture is not 7
        self.assertIn("installation repositories: ['svp-gitops']", out)

    def test_private_vulnerability_reporting_off_fails(self):
        code, out = self.run_check({".enabled": "false"})
        self.assertEqual(code, 1)
        self.assertIn("private vulnerability reporting: false (want true)", out)


    def test_plan_secrets_are_skipped_while_no_env_is_planned(self):
        code, out = self.run_check()
        self.assertEqual(code, 0, out)
        self.assertIn("skip  secrets of svp-infra terraform-plan: SVP_TF_PLAN_ENVS is []", out)

    def test_plan_secrets_of_every_listed_env_pass(self):
        stg = "\n".join(ga.plan_secret_names(["stg"]))
        code, out = self.run_check({".value": '["stg"]', "plan secrets": stg + "\n"})
        self.assertEqual(code, 0, out)
        self.assertIn("svp-infra terraform-plan secret SVP_TFVARS_ENV_STG: True", out)

    def test_a_missing_plan_secret_fails(self):
        have = "\n".join(n for n in ga.plan_secret_names(["stg"]) if n != "SVP_TFVARS_ENV_STG")
        code, out = self.run_check({".value": '["stg"]', "plan secrets": have + "\n"})
        self.assertEqual(code, 1, out)
        self.assertIn("svp-infra terraform-plan secret SVP_TFVARS_ENV_STG: False (want True)", out)

    def test_a_missing_infracost_key_fails(self):
        code, out = self.run_check({"repo secrets": "OTHER\n"})
        self.assertEqual(code, 1, out)
        self.assertIn("svp-infra secret INFRACOST_API_KEY: False (want True)", out)

    def test_a_missing_plan_variable_fails(self):
        code, out = self.run_check({".value": None})
        self.assertEqual(code, 1, out)
        self.assertIn("svp-infra variable SVP_TF_PLAN_ENVS: error:", out)

    def test_plan_secret_names_per_env(self):
        self.assertEqual(ga.plan_secret_names([]), [])
        self.assertEqual(ga.plan_secret_names(["stg", "prd"]), [
            "SVP_AWS_LOG_ACCOUNT_ID", "SVP_AWS_BACKUP_ACCOUNT_ID",
            "SVP_AWS_STG_ACCOUNT_ID", "SVP_TFVARS_ACCOUNT_STG", "SVP_TFVARS_ENV_STG",
            "SVP_AWS_PRD_ACCOUNT_ID", "SVP_TFVARS_ACCOUNT_PRD", "SVP_TFVARS_ENV_PRD",
        ])


class FakeGh:
    """subprocess.run stand-in: records argv, stdin and env of each call, answers by a function of argv."""

    def __init__(self, answer=lambda args: gh_result()):
        self.calls, self.answer = [], answer

    def __call__(self, args, **kw):
        self.calls.append({"args": list(args), "input": kw.get("input"), "env": kw.get("env"), "cwd": kw.get("cwd")})
        return self.answer(list(args))

    def argv_text(self):
        return "\n".join(" ".join(c["args"]) for c in self.calls)


def run_quiet(fn, *args):
    """Run fn; return (exit code, stdout + stderr)."""
    with contextlib.redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(io.StringIO()) as err:
        try:
            fn(*args)
            code = 0
        except SystemExit as exc:
            code = exc.code
    return code, out.getvalue() + err.getvalue()


class Settings(unittest.TestCase):
    def run_settings(self, override=None):
        answers = {".enabled": "true", ".approval_policy": "all_external_contributors", ".state": "configured"}
        answers.update(override or {})

        def answer(args):
            if "-X" in args:
                return gh_result()
            jq = args[args.index("--jq") + 1]
            repo = args[2].split("/")[2]
            return gh_result(answers.get((repo, jq), answers[jq]) + "\n")

        fake = FakeGh(answer)
        with mock.patch.object(ga.subprocess, "run", fake):
            code, out = run_quiet(ga.settings)
        return code, out, fake

    def test_settings_already_right_send_only_gets(self):
        code, out, fake = self.run_settings()
        self.assertEqual(code, 0, out)
        self.assertNotIn("-X", fake.argv_text())
        self.assertEqual(out.count("ok    "), 2 * len(ga.REPOSITORIES) + len(ga.CODEQL_DEFAULT_SETUP))
        self.assertNotIn("changed", out)

    def test_only_the_settings_that_differ_are_written(self):
        code, out, fake = self.run_settings({("svp-labs", ".enabled"): "false",
                                             ("svp-frontend", ".state"): "not-configured",
                                             (".github", ".approval_policy"): "first_time_contributors"})
        self.assertEqual(code, 0, out)
        writes = [c["args"] for c in fake.calls if "-X" in c["args"]]
        self.assertEqual(writes, [
            ["gh", "api", "-X", "PUT", "repos/anhnvcoder/svp-labs/private-vulnerability-reporting"],
            ["gh", "api", "-X", "PUT", "repos/anhnvcoder/.github/actions/permissions/fork-pr-contributor-approval",
             "-f", "approval_policy=all_external_contributors"],
            ["gh", "api", "-X", "PATCH", "repos/anhnvcoder/svp-frontend/code-scanning/default-setup", "-f", "state=configured"],
        ])
        self.assertIn("changed svp-labs private vulnerability reporting", out)
        self.assertIn("changed .github fork pull request approval", out)
        self.assertIn("changed svp-frontend CodeQL default setup", out)
        self.assertIn("ok    svp-backend CodeQL default setup", out)


class Secrets(TempDirs):
    STG, PRD, LOG, BACKUP = "111111111111", "222222222222", "333333333333", "555555555555"
    ACCOUNT_TFVARS, ENV_TFVARS = 'account_id = "x"\nalarm_email = "a@svp.example"\n', 'domain = "svp.example"\n'

    def setUp(self):
        super().setUp()
        env = {"SVP_AWS_STG_ACCOUNT_ID": self.STG, "SVP_AWS_PRD_ACCOUNT_ID": self.PRD,
               "SVP_AWS_LOG_ACCOUNT_ID": self.LOG, "SVP_AWS_BACKUP_ACCOUNT_ID": self.BACKUP}
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)
        for env_name in ("stg", "prd"):
            for root, text in (("accounts", self.ACCOUNT_TFVARS), ("envs", self.ENV_TFVARS)):
                path = self.tmp / "infra" / "aws" / root / env_name / f"{env_name}.auto.tfvars"
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text)

    def secrets(self, env="", answer=lambda args: gh_result()):
        fake = FakeGh(answer)
        with mock.patch.object(ga.subprocess, "run", fake):
            code, out = run_quiet(ga.set_secrets, env)
        return code, out, fake

    def assert_no_value(self, fake, out):
        for value in (self.STG, self.PRD, self.LOG, self.BACKUP, "svp.example"):
            self.assertNotIn(value, fake.argv_text())
            self.assertNotIn(value, out)

    def test_repository_secrets_of_both_ecr_repositories_through_stdin(self):
        code, out, fake = self.secrets()
        self.assertEqual(code, 0, out)
        self.assertEqual([(c["args"], c["input"]) for c in fake.calls], [
            (["gh", "secret", "set", "SVP_AWS_STG_ACCOUNT_ID", "--repo", "anhnvcoder/svp-backend"], self.STG),
            (["gh", "secret", "set", "SVP_AWS_PRD_ACCOUNT_ID", "--repo", "anhnvcoder/svp-backend"], self.PRD),
            (["gh", "secret", "set", "SVP_AWS_STG_ACCOUNT_ID", "--repo", "anhnvcoder/svp-frontend"], self.STG),
            (["gh", "secret", "set", "SVP_AWS_PRD_ACCOUNT_ID", "--repo", "anhnvcoder/svp-frontend"], self.PRD),
        ])
        self.assert_no_value(fake, out)

    def test_plan_secrets_of_an_env_take_their_names_from_plan_secret_names(self):
        code, out, fake = self.secrets("stg")
        self.assertEqual(code, 0, out)
        self.assertEqual([c["args"][3] for c in fake.calls], ga.plan_secret_names(["stg"]))
        for c in fake.calls:
            self.assertEqual(c["args"][4:], ["--env", "terraform-plan", "--repo", "anhnvcoder/svp-infra"])
        given = {c["args"][3]: c["input"] for c in fake.calls}
        self.assertEqual(given, {"SVP_AWS_LOG_ACCOUNT_ID": self.LOG, "SVP_AWS_BACKUP_ACCOUNT_ID": self.BACKUP,
                                 "SVP_AWS_STG_ACCOUNT_ID": self.STG, "SVP_TFVARS_ACCOUNT_STG": self.ACCOUNT_TFVARS,
                                 "SVP_TFVARS_ENV_STG": self.ENV_TFVARS})
        self.assert_no_value(fake, out)

    def test_shared_secrets_are_set_again_with_the_same_value(self):
        first, second = self.secrets("stg")[2], self.secrets("prd")[2]
        shared = lambda fake: [(c["args"], c["input"]) for c in fake.calls if "_LOG_" in c["args"][3]  # noqa: E731
                               or "_BACKUP_" in c["args"][3]]
        self.assertEqual(shared(first), shared(second))
        self.assertEqual(len(shared(first)), 2)

    def test_an_env_outside_stg_prd_is_refused(self):
        code, out, fake = self.secrets("dev")
        self.assertEqual(code, 1)
        self.assertEqual(fake.calls, [])

    def test_a_missing_or_malformed_account_writes_nothing(self):
        for name, value in (("SVP_AWS_PRD_ACCOUNT_ID", None), ("SVP_AWS_PRD_ACCOUNT_ID", "12345"),
                            ("SVP_AWS_PRD_ACCOUNT_ID", "11111111111a"), ("SVP_AWS_LOG_ACCOUNT_ID", None)):
            with self.subTest(name=name, value=value), mock.patch.dict(os.environ):
                os.environ.pop(name)
                if value is not None:
                    os.environ[name] = value
                code, out, fake = self.secrets("prd" if "LOG" in name else "")
                self.assertEqual(code, 1, out)
                self.assertIn(name, out)
                self.assertEqual(fake.calls, [])

    def test_a_missing_or_empty_tfvars_file_writes_nothing(self):
        envs = self.tmp / "infra" / "aws" / "envs" / "stg" / "stg.auto.tfvars"
        envs.write_text("  \n")
        code, out, fake = self.secrets("stg")
        self.assertEqual(code, 1, out)
        self.assertIn("aws/envs/stg/stg.auto.tfvars is missing or empty", out)
        self.assertEqual(fake.calls, [])
        envs.unlink()
        self.assertEqual(self.secrets("stg")[2].calls, [])

    def test_a_failing_gh_prints_no_value(self):
        code, out, fake = self.secrets("stg", lambda args: gh_result(code=1))
        self.assertEqual(code, 1)
        self.assertEqual(len(fake.calls), 1)
        self.assert_no_value(fake, out)


class InfracostKey(unittest.TestCase):
    KEY = "ico-0123456789abcdef"

    def run_key(self, stdin, which=None, cli=None):
        def answer(args):
            if args[0] == "infracost":
                self.assertEqual(args, ["infracost", "configure", "get", "api_key"])
                return cli
            return gh_result()

        fake = FakeGh(answer)
        with mock.patch.object(ga.subprocess, "run", fake), mock.patch.object(ga.sys, "stdin", stdin), \
                mock.patch.object(ga.shutil, "which", return_value=which):
            code, out = run_quiet(ga.infracost_key)
        return code, out, fake

    @staticmethod
    def tty():
        stdin = mock.MagicMock()
        stdin.isatty.return_value = True
        return stdin

    def assert_set_once(self, fake, out):
        sets = [c for c in fake.calls if c["args"][:3] == ["gh", "secret", "set"]]
        self.assertEqual([(c["args"], c["input"]) for c in sets],
                         [(["gh", "secret", "set", "INFRACOST_API_KEY", "--repo", "anhnvcoder/svp-infra"], self.KEY)])
        self.assertNotIn(self.KEY, fake.argv_text())
        self.assertNotIn(self.KEY, out)

    def test_key_from_stdin(self):
        code, out, fake = self.run_key(io.StringIO(self.KEY + "\n"), which="/usr/local/bin/infracost")
        self.assertEqual(code, 0, out)
        self.assert_set_once(fake, out)
        self.assertNotIn("infracost", fake.calls[0]["args"][0])  # stdin wins over the CLI

    def test_key_from_the_cli_when_stdin_is_a_terminal(self):
        code, out, fake = self.run_key(self.tty(), "/usr/local/bin/infracost", gh_result(self.KEY + "\n"))
        self.assertEqual(code, 0, out)
        self.assert_set_once(fake, out)

    def test_no_stdin_and_no_cli_names_both_ways(self):
        code, out, fake = self.run_key(self.tty())
        self.assertEqual(code, 1)
        self.assertIn("Org Settings", out)
        self.assertIn("infracost auth login", out)
        self.assertEqual(fake.calls, [])

    def test_a_failing_or_silent_cli_is_refused(self):
        for cli in (gh_result(code=1), gh_result("")):
            with self.subTest(cli=cli):
                code, out, fake = self.run_key(self.tty(), "/usr/local/bin/infracost", cli)
                self.assertEqual(code, 1)
                self.assertEqual(len(fake.calls), 1)

    def test_empty_multiline_or_spaced_keys_are_refused_and_not_printed(self):
        for text in ("", "\n", "ico-a\nico-b\n", "ico-a b", " ico-a", "ico-a\tb"):
            with self.subTest(text=text):
                code, out, fake = self.run_key(io.StringIO(text))
                self.assertEqual(code, 1)
                self.assertEqual(fake.calls, [])
                if text.strip():
                    self.assertNotIn("ico-a", out)


class Tfvars(TempDirs):
    VALUES = {"SVP_GITOPS_APP_CLIENT_ID": "Iv23liAAA", "SVP_WEB_APP_CLIENT_ID": "Iv23liBBB",
              "SVP_RELEASE_APP_CLIENT_ID": "Iv1.ccc", "SVP_TF_PLAN_ENVS": '["stg"]'}
    WANT = ('svp_gitops_app_client_id = "Iv23liAAA"\nsvp_web_app_client_id = "Iv23liBBB"\n'
            'svp_release_app_client_id = "Iv1.ccc"\nterraform_plan_envs = ["stg"]\n')

    def run_tfvars(self, override=None):
        values = dict(self.VALUES, **(override or {}))

        def answer(args):
            self.assertEqual(args[:2], ["gh", "api"])
            got = values[args[2].rsplit("/", 1)[1]]
            return got if isinstance(got, subprocess.CompletedProcess) else gh_result(got + "\n")

        fake = FakeGh(answer)
        with mock.patch.object(ga.subprocess, "run", fake):
            code, out = run_quiet(ga.tfvars)
        return code, out

    @property
    def path(self):
        return ga.GITHUB / "github.auto.tfvars"

    def test_writes_every_variable_mode_600_and_no_temporary_file(self):
        code, out = self.run_tfvars()
        self.assertEqual(code, 0, out)
        self.assertEqual(self.path.read_text(), self.WANT)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(sorted(p.name for p in ga.GITHUB.iterdir()), ["github.auto.tfvars"])
        self.assertNotIn("Iv23liAAA", out)

    def test_a_variable_not_on_github_is_noted_and_its_line_kept(self):
        self.path.write_text('svp_release_app_client_id = "Iv1.fromcreate"\nother = 1\n')
        code, out = self.run_tfvars({"SVP_RELEASE_APP_CLIENT_ID": subprocess.CompletedProcess(
            ["gh"], 1, stdout='{"message":"Not Found"}', stderr="gh: Not Found (HTTP 404)")})
        self.assertEqual(code, 0, out)
        self.assertIn("note  SVP_RELEASE_APP_CLIENT_ID of svp-backend environment release is not on GitHub yet", out)
        self.assertEqual(self.path.read_text(), 'svp_release_app_client_id = "Iv1.fromcreate"\nother = 1\n'
                         'svp_gitops_app_client_id = "Iv23liAAA"\nsvp_web_app_client_id = "Iv23liBBB"\n'
                         'terraform_plan_envs = ["stg"]\n')

    def test_an_error_body_or_a_wrong_shape_leaves_the_file_unchanged(self):
        for override in ({"SVP_WEB_APP_CLIENT_ID": '{"message":"Bad credentials","status":"401"}'},
                         {"SVP_TF_PLAN_ENVS": '{"message":"Bad credentials"}'},
                         {"SVP_TF_PLAN_ENVS": '["stg","dev"]'}, {"SVP_TF_PLAN_ENVS": '["stg","stg"]'},
                         {"SVP_GITOPS_APP_CLIENT_ID": subprocess.CompletedProcess(["gh"], 1, stdout="",
                                                                                  stderr="HTTP 401: Bad credentials")}):
            with self.subTest(override=override):
                self.path.write_text("old\n")
                code, out = self.run_tfvars(override)
                self.assertEqual(code, 1, out)
                self.assertEqual(self.path.read_text(), "old\n")
                self.assertEqual(sorted(p.name for p in ga.GITHUB.iterdir()), ["github.auto.tfvars"])


class PlanApply(TempDirs):
    TOKEN = "gho_faketoken0000"

    def setUp(self):
        super().setUp()
        patcher = mock.patch.dict(os.environ, {"SVP_AWS_MGMT_ACCOUNT_ID": "000000000000"})
        patcher.start()
        self.addCleanup(patcher.stop)
        os.environ.pop("GITHUB_TOKEN", None)
        (self.tmp / "infra" / "aws").mkdir()
        (self.tmp / "infra" / "aws" / "backend.hcl").write_text("bucket = \"x\"\n")

    def run_cmd(self, fn, account="000000000000", sts_code=0, codes=None):
        codes = dict(codes or {})

        def answer(args):
            if args[0] == "aws":
                return subprocess.CompletedProcess(args, sts_code, stdout=account + "\n", stderr="expired")
            if args[:3] == ["gh", "auth", "token"]:
                return gh_result(self.TOKEN + "\n")
            return subprocess.CompletedProcess(args, codes.get(args[1], 0))

        fake = FakeGh(answer)
        with mock.patch.object(ga.subprocess, "run", fake):
            code, out = run_quiet(fn)
        self.assertNotIn(self.TOKEN, fake.argv_text())
        self.assertNotIn(self.TOKEN, out)
        self.assertNotIn("GITHUB_TOKEN", os.environ)
        return code, out, fake

    def terraform_calls(self, fake):
        return [c for c in fake.calls if c["args"][0] == "terraform"]

    def test_plan_checks_the_account_then_inits_and_saves_the_plan(self):
        code, out, fake = self.run_cmd(ga.plan)
        self.assertEqual(code, 0, out)
        sts = fake.calls[0]
        self.assertEqual(sts["args"], ["aws", "sts", "get-caller-identity", "--query", "Account", "--output", "text",
                                       "--region", "ap-southeast-1"])
        self.assertEqual(sts["env"]["AWS_PROFILE"], "anhnv-sso")
        self.assertNotIn("GITHUB_TOKEN", sts["env"])
        tf = self.terraform_calls(fake)
        self.assertEqual([c["args"] for c in tf], [
            ["terraform", "init", "-input=false", "-backend-config=../aws/backend.hcl"],
            ["terraform", "plan", "-input=false", "-out=github.tfplan"],
        ])
        for c in tf:
            self.assertEqual((c["cwd"], c["env"]["GITHUB_TOKEN"], c["env"]["AWS_PROFILE"]),
                             (ga.GITHUB, self.TOKEN, "anhnv-sso"))

    def test_another_account_or_no_session_stops_before_init(self):
        for kw, want in (({"account": "111111111111"}, "another account"),
                         ({"sts_code": 255}, "AWS_PROFILE=anhnv-sso aws sso login --region us-east-1")):
            with self.subTest(kw=kw):
                code, out, fake = self.run_cmd(ga.plan, **kw)
                self.assertEqual(code, 1)
                self.assertIn(want, out)
                self.assertNotIn("111111111111", out)
                self.assertEqual(self.terraform_calls(fake), [])
                self.assertNotIn(["gh", "auth", "token"], [c["args"] for c in fake.calls])

    def test_apply_without_a_saved_plan_is_refused(self):
        code, out, fake = self.run_cmd(ga.apply)
        self.assertEqual(code, 1)
        self.assertIn("make github-plan", out)
        self.assertEqual(fake.calls, [])

    def test_apply_applies_the_saved_plan_deletes_it_and_plans_again(self):
        (ga.GITHUB / "github.tfplan").write_text("plan")
        code, out, fake = self.run_cmd(ga.apply)
        self.assertEqual(code, 0, out)
        self.assertEqual([c["args"] for c in self.terraform_calls(fake)], [
            ["terraform", "apply", "-input=false", "github.tfplan"],
            ["terraform", "plan", "-input=false", "-detailed-exitcode"],
        ])
        self.assertFalse((ga.GITHUB / "github.tfplan").exists())
        self.assertIn("No changes.", out)

    def test_changes_after_apply_fail_and_a_failed_apply_still_deletes_the_plan(self):
        for codes in ({"plan": 2}, {"apply": 1}):
            with self.subTest(codes=codes):
                (ga.GITHUB / "github.tfplan").write_text("plan")
                code, out, fake = self.run_cmd(ga.apply, codes=codes)
                self.assertEqual(code, 1, out)
                self.assertFalse((ga.GITHUB / "github.tfplan").exists())


class Config(unittest.TestCase):
    def test_selftest_passes_on_the_committed_files(self):
        with contextlib.redirect_stdout(io.StringIO()):
            ga.selftest()


if __name__ == "__main__":
    unittest.main()
