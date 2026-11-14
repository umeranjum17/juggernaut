# File lease at spawn

Run `done-done run file-lease` with `JG_BEADS_TEST_BD` and `JG_BEADS_TEST_DOLT` set to the pinned tools.
The real brief and spawn commands over an isolated fixture project and a real Beads store write a lease for the files a ticket names; a second ticket naming a hot file that lease holds is refused with the holder's id and writes no task record, a shared file that is not hot is never refused, and once the holder's task record is gone the waiting ticket starts and takes the lease (screen: none).
