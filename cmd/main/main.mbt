///|
async fn main {
  let argv = @env.args()
  let exit_code = @app.execute(argv[1:]) catch {
    error => {
      println("moon-binstall: \{error}")
      1
    }
  }
  @sys.exit(exit_code)
}
