# -*- coding: utf-8 -*-

thomas_key = """-----BEGIN PGP PUBLIC KEY BLOCK-----
Version: GnuPG v1.0.7 (GNU/Linux)

mQGiBD1JRcERBADIOjwNaBjmv44a3DPJeVwqrdVO6nuYF16UwKXTAh3ZZNAYecD8
a7opNf4yt3TofSKfT2bEiv/hIdAy3LGjKQg54Dou1EqhB8o90RNl5NeWmHIb82Jp
bCSbAXfaEaz6MEIg0MTHBcvtAOHZbKoBuBO5b6nbokmvcyWZXJHQ9zs9dwCg4FSX
cdVBExg+2iBzEzpGyK4EFrsEAKTxf2YoLGihB1HDknvlAWIfa5dBZI9c7pdbpmkW
6nZZ+SEHC9j1VSWFbB1fpA217BPaF6bmKmLoZEdmYLItriy2GEeEnbAcqd9QvQTr
RnXzBlOanC4OHqT0dvBLMH60TsWN2ZQQ3hPInI+CAdgquDzqoZY699moo+NXZZky
bB12A/9aI83jzl8gX7j61hkdk97rL/tcrdp8nGe2mS7y6tLodh89kp0IAD3Cn9pu
bQpEVMSIAO6ocMIMa6IhiSW+axKcW44JaOXtxFhLi9RDnGhds9LKPSB+Qoyfpxkk
zcAjNFcR2tDMOaDD5+/cZHSfKhT6TuWiiAzhhZEw3ikBnhCQYLQtVGhvbWFzIExl
b25hcmQgPHRhbDE5N0B1c2Vycy5zb3VyY2Vmb3JnZS5uZXQ+iFkEExECABkFAj1J
RcEECwcDAgMVAgMDFgIBAh4BAheAAAoJEK4HgoBZpTzBvdUAoMYjTfjeiOLyBF+V
6tm/8Da/VIS2AKDXlYeko8yY/DMZDy9uLrmlrOLYmrkBDQQ9SUXGEAQA40HXju3P
alvuv73gX0PcNC1lVTE3X15DTdvQLCCCt0H62A73i22c80CfGj3LaVybOHPjuM2/
phu69zf5S3wHFJXYzezkVO7Yf/0MRyQslviy/+pWdbBJnVaE+qF3wggvcHIddatd
roJ7q1haFl+cmIf43+EqoDZWVtKejSyeuGsAAwUEAOIrD9sPoing4huSDDgNJ9bo
DbG3YkT9GROZ2FMdz12pwjUvSSxa8Yh4zJQ1EkKprSCD7QZMu9FMudzuwHZweJN1
OhG+amFSsHmYl4Cbql9401lZvpvWoBhi54eKGMaxDNIGyojWJD8FTiC2eUrMwu3G
rXu8m0nbaNiXL88Kv6EHiEYEGBECAAYFAj1JRcYACgkQrgeCgFmlPMHF8ACfehcT
YkxNRG4ozQP5gwBO8CDdGVAAn0P7xyghEym4gcy7/rvwkY7JIar5
=wks3
-----END PGP PUBLIC KEY BLOCK-----
"""

foo_signed_xml = """<?xml version="1.0" ?>
<interface uri="http://foo" xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>Foo</name>
  <summary>Foo</summary>
  <description>Foo (check non-ASCII chars úüû)</description>
</interface>
<!-- Base64 Signature
iD8DBQBE1Z21rgeCgFmlPMERApswAJ43LSCUPXhd4FfyS/GfVtoOhzBHqgCgngVu4Yiap6ipOfO4
04M7BexGZLc=

-->
"""

new_foo_signed_xml = """<?xml version="1.0" ?>
<interface uri="http://foo" xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>Foo</name>
  <summary>Foo</summary>
  <description>Foo (check non-ASCII chars úüû)</description>
  <!-- Updated! -->
</interface>
<!-- Base64 Signature
iD8DBQBE1Z3VrgeCgFmlPMERApXYAJ42erHAoTU4LNRRxM4kt3lSqud66wCgrgQOQ/QLiRVT6z7f
zNaZYKyBM4c=

-->
"""
