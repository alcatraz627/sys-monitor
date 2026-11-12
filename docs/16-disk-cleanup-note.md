# Disk and cleanup belongs here

Owner ruling, 2026-09-25, recorded 2026-09-29: disk usage and cleanup belong in
sys-monitor, not in Switchboard. Switchboard's backlog had it as "Disk and
cleanup"; it was moved out when the Switchboard roadmap was written
(`~/Code/Claude/switchboard-mac/docs/plans/20260929-roadmap.md`).

Nothing is specified yet. When it is picked up, the natural scope is what
sys-monitor already measures: free space per volume, the biggest folders under
home, and caches that are safe to clear. Switchboard keeps only mounted drives
(eject, open) and never deletes files.
