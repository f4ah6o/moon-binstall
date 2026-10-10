///|
async fn main {
  let argv = @env.args()
  let exit_code = execute(argv[1:]) catch {
    error => {
      println("moon-binstall: \{error}")
      1
    }
  }
  @sys.exit(exit_code)
}
