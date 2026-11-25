# RemoteDebug repository instructions

## Release completion

- A task is complete only when all its changes are merged into `main`, the landing commit is on `origin/main`, and every release destination in scope has been verified.
- Identify the release destinations and how to verify each one before landing the change. Include every affected release channel. Record the reason for excluding an unaffected channel.
- Local tests, local installation, a signed archive, and a draft release are intermediate milestones. While any completion condition remains open, report the last verified milestone and what is pending.
- Follow the task's authorization for merging, pushing, and publishing. Completion criteria do not override an instruction to keep work local. Use authorization already granted for the task.
- Follow the [release procedure](docs/release.md). Record the landing commit, the published version or build, the destination, and the verification result in the completion report.
