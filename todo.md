- migrate to python REPL using Monty interpreter
- enable resizing panels in web UI
- figure out why some agents are marked as "running" in the UI even though they are no longer looping. Note: they never submitted final_answer. why did they stop looping? crash?
- mention prompt refinement in the sysprompt. sometimes handing off with a better prompt is "monotonic enough."
- use a more general model. qwen coder is too codemaxxed. brittle. 
- up preview size?
- change the name of "context" variable. thats confusing with context window. 
- stop button should stop ALL subagents.  
    - persist somehow? or just kill?

- do a general tidy up. this repo is getting bloated af. reduce lines, drop redundancies, refactor for concision, identify and cut vestigial stuff. 

- fix this issue with context window logs:
    [PRINCIPAL]     <<<< here
    [SYSTEM]
    Workspace access is read-write. Use ls(), read_file(), edit_file(), and create_file() with relative paths.

    [PRINCIPAL]
    hello world!


- think more about what context should be shown to the agent.
- Think more about how agents can pass bindings to each other, and how to prompt for this. 
- think more about how to prompt for effective delegation. provide enough context, clear task, clear deliverable.
    - let agents see their parents context?

- let root see event log status of subagents?? probably not. 


