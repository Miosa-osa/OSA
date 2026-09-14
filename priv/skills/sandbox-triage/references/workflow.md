# Worked workflow

Read-only inventory on a copied sample:
```sh
sha256sum case/sample.bin
```
Optional YARA source-rule scan, only after `command -v yara` and checking installed `yara --help`:
```sh
yara -a 10 lab/marker.yar case/sample.bin
```
Original harmless control rule:
```text
rule OSA_Defense_Marker {
  strings:
    $marker = "OSA_DEFENSE_TEST_MARKER"
  condition:
    $marker
}
```
A plain text file containing the marker must match; a plain text file containing `ordinary invoice text` must not. This tests scanner wiring, not malware detection quality. Exit errors/timeouts are failed analysis, not clean samples. Do not load third-party compiled rules with `-C`; retain sample bytes without executing them.

## Primary references

- [YARA command line](https://yara.readthedocs.io/en/stable/commandline.html)

Original OSA examples; no third-party rules or source text copied. Consult the linked publisher terms before redistributing upstream material.
