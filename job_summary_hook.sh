#!/bin/bash
# job_summary_hook.sh - GHA runner hook: renders VM metrics for the job that just ran
# Configured via ACTIONS_RUNNER_HOOK_JOB_COMPLETED in the runner's .env
#
# Writes:
#   - Mermaid line charts + a stats table to the job summary ($GITHUB_STEP_SUMMARY)
#   - ASCII charts + stats to the job log (under the "Complete runner" step)
#
# No tokens, no network: GitHub runs this hook inside the job, so it can use
# workflow commands and environment files like any other step.
#
# Optional env (set in daemon.env or the runner's .env):
#   MAX_POINTS - max data points per line chart (default 60; samples are bucketed by max)
#   SUMMARY_LAYOUT - "full" (default): one chart per row at full width;
#                    "side": two charts per row (GitHub sizes them to the cell, so they're small)
#   MEM_POINTS - points in the stacked memory chart (default 150; interpolated
#                when the job has fewer samples so the bars read as smooth areas)

OUTPUT_DIR="${OUTPUT_DIR:-/tmp/gha-monitoring}"
MAX_POINTS="${MAX_POINTS:-60}"
MEM_POINTS="${MEM_POINTS:-150}"
DAEMON_ENV="/usr/local/bin/gha-monitoring/daemon.env"

[ -f "$DAEMON_ENV" ] && source "$DAEMON_ENV"

# Fallback when daemon.env predates MONITORING_VERSION (older pasted warmup script):
# read the commit from the clone the warmup left behind.
if [ -z "$MONITORING_VERSION" ] && [ -d /tmp/gha-monitoring-setup/.git ]; then
    MONITORING_VERSION="$(git -C /tmp/gha-monitoring-setup rev-parse --abbrev-ref HEAD 2>/dev/null)@$(git -C /tmp/gha-monitoring-setup rev-parse --short HEAD 2>/dev/null)"
fi
SUMMARY_LAYOUT="${SUMMARY_LAYOUT:-full}"

CSV=$(ls -t "$OUTPUT_DIR"/monitoring-*.csv 2>/dev/null | head -1)

if [ -z "$CSV" ]; then
    echo "job_summary_hook: no metrics file found in $OUTPUT_DIR, skipping"
    exit 0
fi

ROWS=$(($(wc -l < "$CSV") - 1))
if [ "$ROWS" -lt 2 ]; then
    # Still leave a trace in the summary so every job shows up.
    echo "job_summary_hook: only $ROWS sample(s) in $(basename "$CSV") - job too short for charts"
    if [ -n "$GITHUB_STEP_SUMMARY" ]; then
        {
            echo "## 🖥️ Runner VM metrics"
            echo ""
            echo "\`${VM_NAME:-$(hostname)}\` · job too short for charts ($ROWS sample(s) in \`$(basename "$CSV")\`)."
            [ "$ROWS" -eq 1 ] && tail -1 "$CSV" | awk -F',' '{ printf "\n| CPU | Memory used | Load (1m) | Swap used |\n|---|---|---|---|\n| %.1f%% | %.1f / %.1f GB | %s | %.1f GB |\n", $2+$3, $6/1024, ($6+$7+$8)/1024, $9, $12/1024 }'
            echo ""
            echo "<sub>monitoring ${MONITORING_VERSION:-unknown}</sub>"
        } >> "$GITHUB_STEP_SUMMARY"
    fi
    exit 0
fi

VM_LABEL="${VM_NAME:-$(hostname)}"

# ---------------------------------------------------------------------------
# render <mode>   mode = summary | log
# One awk pass loads the CSV, computes stats, buckets samples down to
# MAX_POINTS (keeping the max of each bucket so spikes stay visible) and
# prints either Markdown/Mermaid or ASCII. POSIX awk only (macOS BSD awk).
# ---------------------------------------------------------------------------
render() {
    awk -F',' -v mode="$1" -v maxp="$MAX_POINTS" -v memp="$MEM_POINTS" -v vm="$VM_LABEL" -v file="$(basename "$CSV")" -v ver="${MONITORING_VERSION:-unknown}" -v layout="$SUMMARY_LAYOUT" '
    function secs(ts,   d, t) {            # "YYYY-MM-DD HH:MM:SS" -> seconds (day-aware)
        split(ts, d, " "); split(d[2], t, ":")
        return substr(d[1], 9, 2) * 86400 + t[1] * 3600 + t[2] * 60 + t[3]
    }
    function r1(x) { return sprintf("%.1f", x) }
    function series(arr, cnt,   i, s) {
        if (cnt == "") cnt = nb
        s = ""
        for (i = 1; i <= cnt; i++) s = s (i > 1 ? ", " : "") r1(arr[i])
        return "[" s "]"
    }
    function ceilnice(x) {               # round a y-axis max up to something readable
        if (x <= 1) return 1
        if (x <= 5) return int(x + 0.999)
        if (x <= 20) return int((x + 1.999) / 2) * 2
        return int((x + 9.999) / 10) * 10
    }
    function mchart(title, ylab, ymax, a, b, palette) {
        print "```mermaid"
        print "%%{init: {\"xyChart\": {\"width\": 900, \"height\": 500}, \"themeVariables\": {\"xyChart\": {\"plotColorPalette\": \"" palette "\"}}}}%%"
        print "xychart-beta"
        print "    title \"" title "\""
        print "    x-axis \"Elapsed (min)\" 0 --> " r1(dur / 60 > 0.1 ? dur / 60 : 0.1)
        print "    y-axis \"" ylab "\" 0 --> " ymax
        print "    line " series(a)
        if (b != "") {
            if (b == "sys")    print "    line " series(bsys)
            if (b == "load5")  print "    line " series(bl5)
        }
        print "```"
    }
    function mstacked(title, ylab, ymax, palette) {
        # xychart has no native stacking: draw cumulative bars largest-first so
        # each smaller bar is painted over the bigger one, which reads as a stack.
        print "```mermaid"
        print "%%{init: {\"xyChart\": {\"width\": 900, \"height\": 500}, \"themeVariables\": {\"xyChart\": {\"plotColorPalette\": \"" palette "\"}}}}%%"
        print "xychart-beta"
        print "    title \"" title "\""
        print "    x-axis \"Elapsed (min)\" 0 --> " r1(dur / 60 > 0.1 ? dur / 60 : 0.1)
        print "    y-axis \"" ylab "\" 0 --> " ymax
        print "    bar " series(m3, nm)
        print "    bar " series(m2, nm)
        print "    bar " series(m1, nm)
        print "```"
    }
    function astacked(title, ymax,   h, row, i, line, thr, c) {
        h = 8
        printf "%s (max %s GB)   # used   + reclaimable   . free\n", title, r1(ymax)
        for (row = h; row >= 1; row--) {
            thr = ymax * (row - 0.5) / h
            line = sprintf("%7s |", (row == h ? r1(ymax) : (row == 1 ? "0" : "")))
            for (i = 1; i <= nb; i++) {
                c = " "
                if (stk3[i] >= thr) c = "."
                if (stk2[i] >= thr) c = "+"
                if (stk1[i] >= thr) c = "#"
                line = line c
            }
            print line
        }
        line = "        +"; for (i = 1; i <= nb; i++) line = line "-"; print line
        printf "         0%" (nb > 10 ? nb - 9 : 1) "s%s\n", "", r1(dur / 60) " min"
        print ""
    }
    # Layout helpers: side-by-side = a 100%-wide two-cell table; full = plain rows.
    # Blank lines around content are required for GitHub to render Markdown in <td>.
    function row_open()  { if (layout == "side") { print "<table width=\"100%\"><tr><td width=\"50%\" valign=\"top\">"; print "" } }
    function row_mid()   { print ""; if (layout == "side") { print "</td><td width=\"50%\" valign=\"top\">"; print "" } }
    function row_close() { print ""; if (layout == "side") print "</td></tr></table>" }
    function ascii(title, unit, arr, ymax,   h, row, i, line, thr) {
        h = 8
        printf "%s (max %s%s)\n", title, r1(ymax), unit
        for (row = h; row >= 1; row--) {
            thr = ymax * (row - 0.5) / h
            line = sprintf("%7s |", (row == h ? r1(ymax) : (row == 1 ? "0" : "")))
            for (i = 1; i <= nb; i++) line = line (arr[i] >= thr ? "#" : " ")
            print line
        }
        line = "        +"; for (i = 1; i <= nb; i++) line = line "-"; print line
        printf "         0%" (nb > 10 ? nb - 9 : 1) "s%s\n", "", r1(dur / 60) " min"
        print ""
    }
    NR == 1 { next }
    NF < 13 { next }
    {
        n++
        t[n] = secs($1); if (n == 1) t0 = t[n]
        cpu[n] = $2 + $3; sys[n] = $3
        mu[n] = $6 / 1024; mf[n] = $7 / 1024; mc[n] = $8 / 1024
        if (mu[n] + mc[n] + mf[n] > ptot) ptot = mu[n] + mc[n] + mf[n]
        l1[n] = $9; l5[n] = $10; sw[n] = $12 / 1024
        if (n == 1) { ram = ($6 + $7 + $8) / 1024; start = $1 }
        stop = $1
        cpusum += cpu[n]
        if (cpu[n] > pcpu) pcpu = cpu[n]
        if (mu[n]  > pmu)  pmu  = mu[n]
        if (l1[n]  > pl1)  pl1  = l1[n]
        if (sw[n]  > psw)  psw  = sw[n]
    }
    END {
        if (n < 2) exit
        dur = t[n] - t0; if (dur < 0) dur += 86400 * 31
        # bucket samples
        nb = (n < maxp ? n : maxp)
        for (i = 1; i <= n; i++) {
            b = int((i - 1) * nb / n) + 1
            if (cpu[i] > bcpu[b])  bcpu[b]  = cpu[i]
            if (sys[i] > bsys[b])  bsys[b]  = sys[i]
            if (!(b in bmi) || mu[i] > mu[bmi[b]]) bmi[b] = i   # sample with peak used memory
            if (l1[i]  > bl1[b])   bl1[b]   = l1[i]
            if (l5[i]  > bl5[b])   bl5[b]   = l5[i]
            if (sw[i]  > bsw[b])   bsw[b]   = sw[i]
        }
        for (b = 1; b <= nb; b++) {          # memory stack from that one sample, so it sums to total
            i = bmi[b]
            bmu[b] = mu[i]; stk1[b] = mu[i]; stk2[b] = mu[i] + mc[i]; stk3[b] = mu[i] + mc[i] + mf[i]
        }
        # Memory chart for the summary: finer resolution so the stacked bars read
        # as smooth areas. Fewer samples than memp -> linear interpolation between
        # neighbouring samples; more -> bucket by peak used memory as above.
        nm = memp
        if (n >= nm) {
            for (i = 1; i <= n; i++) {
                b = int((i - 1) * nm / n) + 1
                if (!(b in mmi) || mu[i] > mu[mmi[b]]) mmi[b] = i
            }
            for (b = 1; b <= nm; b++) {
                i = mmi[b]; m1[b] = mu[i]; m2[b] = mu[i] + mc[i]; m3[b] = mu[i] + mc[i] + mf[i]
            }
        } else {
            for (b = 1; b <= nm; b++) {
                p = 1 + (b - 1) * (n - 1) / (nm - 1); lo = int(p); f = p - lo; hi = (lo < n ? lo + 1 : n)
                u  = mu[lo] + (mu[hi] - mu[lo]) * f
                c  = mc[lo] + (mc[hi] - mc[lo]) * f
                fr = mf[lo] + (mf[hi] - mf[lo]) * f
                m1[b] = u; m2[b] = u + c; m3[b] = u + c + fr
            }
        }
        avgcpu = cpusum / n
        memmax = ceilnice(ptot > ram ? ptot : ram)
        loadmax = ceilnice(pl1)
        if (mode == "summary") {
            print "## 🖥️ Runner VM metrics"
            print ""
            print "`" vm "` · " n " samples · " start " → " stop " (" r1(dur / 60) " min) · `" file "`"
            print ""
            print "| CPU avg | CPU peak | Memory peak | Load peak (1m) | Swap peak |"
            print "|---|---|---|---|---|"
            printf "| %s%% | %s%% | %s / %s GB | %s | %s GB |\n", r1(avgcpu), r1(pcpu), r1(pmu), r1(ram), r1(pl1), r1(psw)
            print ""
            # Two collapsible sections, each with two charts (see row_* helpers).
            print "<details open>"
            print "<summary><b>CPU & memory</b> — CPU peak " r1(pcpu) "% · memory peak " r1(pmu) " / " r1(ram) " GB</summary>"
            print ""
            row_open()
            print "**CPU %** — 🔵 user + system · 🟠 system"
            print ""
            mchart("CPU %", "%", 100, bcpu, "sys", "#2563eb, #f97316")
            row_mid()
            print "**Memory (GB)** — 🔵 used · 🟢 reclaimable · ⚪ free"
            print ""
            mstacked("Memory (GB)", "GB", memmax, "#9ca3af, #16a34a, #2563eb")
            row_close()
            print "</details>"
            print ""
            print "<details>"
            print "<summary><b>Load & swap</b> — load peak " r1(pl1) " · swap peak " r1(psw) " GB" (psw > 0 ? " ⚠️" : "") "</summary>"
            print ""
            row_open()
            print "**Load average** — 🔵 1m · 🟣 5m"
            print ""
            mchart("Load average", "load", loadmax, bl1, "load5", "#2563eb, #9333ea")
            row_mid()
            print "**Swap used (GB)** — non-zero means the VM ran out of RAM"
            print ""
            if (psw > 0) mchart("Swap used (GB)", "GB", ceilnice(psw), bsw, "", "#dc2626")
            else         print "✅ No swap used during this job."
            row_close()
            print "</details>"
            print ""
            print "<sub>Each point is the max of its time bucket (" nb " points from " n " samples) · monitoring " ver "</sub>"
        } else {
            print "Monitoring version: " ver
            printf "VM: %s  |  %d samples  |  %s -> %s (%s min)\n", vm, n, start, stop, r1(dur / 60)
            printf "CPU avg %s%%  peak %s%%  |  Mem peak %s/%s GB  |  Load1 peak %s  |  Swap peak %s GB\n\n", \
                r1(avgcpu), r1(pcpu), r1(pmu), r1(ram), r1(pl1), r1(psw)
            ascii("CPU % (user+system)", "%", bcpu, 100)
            astacked("Memory (GB)", memmax)
            ascii("Load average (1m)", "", bl1, loadmax)
            if (psw > 0) ascii("Swap used (GB)", " GB", bsw, ceilnice(psw))
        }
    }' "$CSV"
}

# --- Job log -----------------------------------------------------------------
echo "::group::VM metrics ($(basename "$CSV"))"
render log
echo "::endgroup::"

# --- Job summary -------------------------------------------------------------
if [ -n "$GITHUB_STEP_SUMMARY" ]; then
    render summary >> "$GITHUB_STEP_SUMMARY"
    echo "job_summary_hook: charts written to job summary"
else
    echo "job_summary_hook: GITHUB_STEP_SUMMARY not available, log output only"
fi

exit 0
