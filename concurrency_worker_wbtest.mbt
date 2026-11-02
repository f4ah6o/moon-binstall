///|
/// Spawned by the process integration test; ordinary test runs skip this body.
async test "fixture install process worker" {
  guard @env.get_env_var("MOON_BINSTALL_TEST_ROOT") is Some(root) else {
    return
  }
  guard @env.get_env_var("MOON_BINSTALL_TEST_TAG") is Some(tag) else {
    fail("missing tag")
  }
  let newer = tag == "v1.2.0"
  let content = if newer { "newer\n" } else { "older\n" }
  let version = if newer { "1.2.0" } else { "1.1.0" }
  let transport = make_github_release_transport(root, tag, version, content)
  @stdio.stdout.write("WORKER_READY\n")
  let result = try {
    if newer {
      install_many_using(
        github_options(root + "/bin", tag, false),
        PausedFixture(transport, () => {
          @stdio.stdout.write("LOCK_HELD\n")
          ignore(@stdio.stdin.read_exactly(1))
        }),
      )
    } else {
      install_many_using(
        github_options(root + "/bin", tag, false),
        WaitingFixture(transport, () => @stdio.stdout.write("LOCK_WAITING\n")),
      )
    }
    true
  } catch {
    InstallError(stage=Destination, reason~, ..) if !newer &&
      reason.contains("older than") => false
    err => raise err
  }
  if newer {
    assert_true(result)
  } else {
    assert_true(!result)
  }
  @stdio.stdout.write("WORKER_DONE\n")
}
