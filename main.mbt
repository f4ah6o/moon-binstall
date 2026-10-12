///|
async fn main {
  let argv = @env.args()
  let exit_code = execute(argv[1:]) catch { error => report_error(error) }
  @sys.exit(exit_code)
}
