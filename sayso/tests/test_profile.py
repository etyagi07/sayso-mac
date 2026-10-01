"""Account selection: each account keeps its own session and daily
allowance, so one can never be used with another's login."""

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import _isolated  # noqa: E402,F401  (state in a temp folder, never the live one)

from shoonya import profile  # noqa: E402


def isolated(fn):
    def run():
        saved = os.environ.pop(profile.VAR, None)
        try:
            fn()
        finally:
            os.environ.pop(profile.VAR, None)
            if saved is not None:
                os.environ[profile.VAR] = saved
    run.__name__ = fn.__name__
    return run


@isolated
def test_state_lives_beside_the_code_by_default():
    saved = os.environ.pop(profile.HOME_VAR, None)
    try:
        assert profile.home() == profile.ROOT
        assert profile.session_file().parent == profile.ROOT
    finally:
        if saved is not None:
            os.environ[profile.HOME_VAR] = saved


@isolated
def test_an_app_can_put_state_in_a_per_user_folder():
    import tempfile
    saved = os.environ.get(profile.HOME_VAR)
    with tempfile.TemporaryDirectory() as d:
        where = Path(d) / "Sayso"                       # not there yet
        os.environ[profile.HOME_VAR] = str(where)
        try:
            for f in (profile.session_file(), profile.account_file(),
                      profile.limits_file()):
                assert f.parent == where, f
            assert where.is_dir(), "created on first use"
        finally:
            if saved is None:
                os.environ.pop(profile.HOME_VAR, None)
            else:
                os.environ[profile.HOME_VAR] = saved


@isolated
def test_accounts_are_listed_by_name_only():
    import tempfile
    saved = os.environ.get(profile.HOME_VAR)
    with tempfile.TemporaryDirectory() as d:
        os.environ[profile.HOME_VAR] = d
        try:
            for name in (".session.json", ".session.client.json", ".session.b2.json",
                         ".account.other.json"):
                (Path(d) / name).write_text("{}")
            assert profile.accounts() == ["default", "b2", "client"]
        finally:
            if saved is None:
                os.environ.pop(profile.HOME_VAR, None)
            else:
                os.environ[profile.HOME_VAR] = saved


@isolated
def test_default_account_uses_the_plain_files():
    assert profile.session_file().name == ".session.json"
    assert profile.limits_file().name == ".daily_limits.json"


@isolated
def test_named_account_has_its_own_files():
    argv = ["main", "--account", "client", "--other"]
    assert profile.from_argv(argv) == "client"
    assert argv == ["main", "--other"], "flag should be consumed"
    assert profile.session_file().name == ".session.client.json"
    assert profile.limits_file().name == ".daily_limits.client.json"


@isolated
def test_equals_form():
    assert profile.from_argv(["main", "--account=mine"]) == "mine"


@isolated
def test_unsafe_names_are_refused():
    # The name becomes part of a filename.
    for bad in ("../x", "a/b", "", "x" * 40):
        try:
            profile.from_argv(["main", "--account", bad])
        except SystemExit:
            continue
        raise AssertionError(f"accepted account name {bad!r}")


@isolated
def test_hints_name_this_python_and_this_account():
    # Hints said bare "python" - missing on a Mac, the wrong Python on
    # Windows - and dropped --account, so following one acted on the
    # default account.
    hint = profile.cmd("shoonya.login")
    assert not hint.startswith("python "), hint
    assert "python" in hint and hint.endswith("-m shoonya.login"), hint
    profile.from_argv(["main", "--account", "client"])
    assert profile.cmd("shoonya.login").endswith("--account client")
    assert "--account" not in profile.cmd("pip", "install", account=False)


if __name__ == "__main__":
    passed = failed = 0
    for name, fn in sorted(globals().items()):
        if not name.startswith("test_"):
            continue
        try:
            fn()
            passed += 1
            print(f"ok   {name}")
        except Exception as e:
            failed += 1
            print(f"FAIL {name}: {type(e).__name__}: {e}")
    print(f"\n{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)
