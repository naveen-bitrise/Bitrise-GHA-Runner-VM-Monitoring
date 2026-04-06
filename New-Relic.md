1. Collect data to show dashboards as shown in Bitrise Insights. See ![New-Relic-Dashoard-Ref](New-Relic-Dashoard-Ref.png)
    * total build time (p90, p50), failure rate, build count, total duration over time
    * it can be drilled down by
    * Machine type: Mac or Linux
        * Machine Sub type: 7vCPU, 14 vCPU
    * Workflow name
        * Workflow step
    
    * Also show VM monitoring graphs in the repo.

2. Create a new branch new-relic where we will modify all scripts

3. Post data to new-relic in the same ACTIONS_RUNNER_HOOK_JOB_COMPLETED hook 

4. Create new relic dashboards to show the data.