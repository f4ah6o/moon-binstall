///|
/// Pause the older update after its decision, finish the newer update, then
/// release_gate the older one. Both use local fixtures and no scheduler timing.
async test "concurrent managed updates do not roll back a newer release" {
  let root = @fs.tmpdir(prefix="moon-binstall-race")
  defer (@fs.rmdir(root, recursive=true) catch { _ => () })
  let bin_dir = root + "/bin"
  let initial = make_github_release_transport(
    root, "v1.0.0", "1.0.0", "initial\n",
  )
  let older = make_github_release_transport(root, "v1.1.0", "1.1.0", "older\n")
  let newer = make_github_release_transport(root, "v1.2.0", "1.2.0", "newer\n")
  install_many_using(github_options(bin_dir, "v1.0.0", false), Fixture(initial))
  let reached = @cond_var.Cond()
  let release_gate = @cond_var.Cond()
  @async.with_task_group(group => {
    let first = group.spawn(() => {
      install_many_using(
        github_options(bin_dir, "v1.1.0", false),
        PausedFixture(older, () => {
          reached.signal()
          release_gate.wait()
        }),
      )
    })
    reached.wait()
    install_many_using(github_options(bin_dir, "v1.2.0", false), Fixture(newer))
    release_gate.signal()
    first.wait()
  })
  assert_eq(@fs.read_file(bin_dir + "/tool").text(), "newer\n")
  let receipt = read_receipt_file(receipt_path(bin_dir, "tool"))
  guard receipt is Some(value) else { fail("missing receipt") }
  assert_eq(value.tag, "v1.2.0")
  assert_eq(value.binary_digest, file_sha256(bin_dir + "/tool"))
}
