/*
    Canary rule — validates the whole chain without touching malware.

    Managed by Ansible (role: yara). Deployed into the local rules directory.

    The chain to validate has five hops, and any of them can be broken without it showing:

        FIM sees the file
          -> the manager raises alert 554
          -> the manager fires active response on THAT agent
          -> yara.sh scans and writes to active-responses.log
          -> the agent ships that log
          -> the manager's decoder and custom rule raise the final alert

    Testing with real malware only tells you whether the whole thing works. This lets you
    provoke the round trip at will, on a lab host, and see which hop it stops at when
    something fails.

    Usage:
        printf 'WAZUH_YARA_CANARY_a7f3e1' | sudo tee /usr/bin/canary-test >/dev/null
        # wait for the alert, then:
        sudo rm /usr/bin/canary-test

    The string is deliberately improbable so it never matches a legitimate binary by
    accident.
*/

rule WAZUH_Canary_ChainTest
{
    meta:
        author = "wazuh-siem-iac"
        description = "Test file validating FIM -> active response -> YARA -> alert"
        severity = "info"
        reference = "docs/YARA.md"

    strings:
        $canary = "WAZUH_YARA_CANARY_a7f3e1" ascii

    condition:
        $canary
}
