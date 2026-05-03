# Compiler Errors

Below is the current list of compiler errors in the project.

1. **Sending 'self.diarizer' risks causing data races**  
   *File: RealtimeDiarizationService.swift*  
   Inside the `MainActor.assumeIsolated` closure, `self.diarizer` is being sent into a `Task` block. Even though `self` is isolated to the main actor at the point of capture, the `Task` closure is not guaranteed to execute on the same actor, and sending a main-actor-isolated reference (`self.diarizer`) across concurrency domains can introduce data races. Consider capturing a local copy or restructuring to avoid the warning.
