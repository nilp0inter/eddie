import eddie_shared/task
import gleeunit/should

pub fn status_to_string_test() {
  task.status_to_string(task.Pending)
  |> should.equal("pending")

  task.status_to_string(task.InProgress)
  |> should.equal("in_progress")

  task.status_to_string(task.Done)
  |> should.equal("done")
}

pub fn parse_status_test() {
  task.parse_status("pending")
  |> should.equal(Ok(task.Pending))

  task.parse_status("in_progress")
  |> should.equal(Ok(task.InProgress))

  task.parse_status("done")
  |> should.equal(Ok(task.Done))
}

pub fn parse_status_invalid_test() {
  task.parse_status("unknown")
  |> should.be_error()
}

pub fn status_icon_test() {
  task.status_icon(task.Pending)
  |> should.equal("[ ]")

  task.status_icon(task.InProgress)
  |> should.equal("[~]")

  task.status_icon(task.Done)
  |> should.equal("[x]")
}
