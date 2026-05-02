# Compiler Errors

Below is the current list of compiler errors in the project.

1. **Actor-isolated property 'speakerCount' can not be referenced from the main actor**  
   *Occurs in three separate locations.*  
   Likely accessing a non-isolated property from a `@MainActor` context where the property belongs to a different actor (e.g., a dedicated actor for speaker management).

2. **Call to actor-isolated instance method 'reset(keepIfPermanent:)' in a synchronous main actor-isolated context**  
   The method `reset(keepIfPermanent:)` is actor-isolated (probably on a different actor) and is being called synchronously from the main actor. An `await` is required.

3. **'async' call in a function that does not support concurrency**  
   An `async` function is being called from a synchronous context. The caller needs to be marked `async` or the call needs to be moved into a `Task` block.
