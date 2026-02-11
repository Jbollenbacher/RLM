

- UI should have "show system prompt" toggle to show the system prompt in context history. by default, dont show it.

- Agent turns look duplicated.

- the agent's REPL is printing the final_answer variable, creating a redundancy in the context transcript. 

- agents sometimes use IO.puts (or similar) to try to respond to the user. Sometimes this is reflected back at them by the REPL and they get confused, thinking the use echoed them. Agents should *only* respond to the principal using `final_answer = your_answer`




