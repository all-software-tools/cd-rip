# AccurateRip development integration

Available in the 0.5.0 public beta, with online database access disabled.

Online access is disabled by `AccurateRipAccess.databaseApproved`. Illustrate requires prior agreement for every third-party application, including noncommercial applications. Do not enable or distribute online access before obtaining an agreement and completing interoperability checks. No audio is uploaded by this integration.

## Result handling

| Result | Action after successful local read checks |
| --- | --- |
| Verified | Convert; record matched checksum version and confidence. |
| Not in database / no usable track reference | Convert; retain an explicitly unverified status. |
| Service unavailable / malformed response | Convert; report unavailable, never verified or absent. |
| Access pending / lookup disabled | Compute local checksums and convert; remain unverified. |
| Mismatch | Retry the full track up to the configured limit. If still unmatched, preserve every WAV and report, pause automatic conversion for this track, and continue other tracks. |
| Local read or WAV validation error | Preserve recovery data and block conversion. |

A mismatch does not prove an audible defect. Different pressings, offsets, modified recordings and CDs made from lossy audio may differ from references. A database match is not an authenticity, ownership or licensing check. A self-made compilation may have no reference at all.

## Implementation

- Compute v1 and v2 before lossy encoding, using stereo 16-bit little-endian PCM at 44.1 kHz.
- Validate RIFF size, PCM format, complete chunks and exact sample count against the TOC.
- Use the full physical audio TOC even when ripping selected tracks. Exclude the first 2939 stereo frames of physical track 1 and the last 2940 of the final physical track, following the checksum convention.
- Strictly parse 13-byte disc headers and 9-byte track records. The second CRC field is an offset-finding checksum, **not** a v2 checksum. Prefer a v2 match; retain confidence from a single best record, without adding duplicate records together.
- A future approved client makes one lookup per disc per rip, with bounded timeouts and a 1 MiB limit. HTTP 404 means absent; other failures mean unavailable. Reject cross-host or non-HTTPS redirects. The default client makes no database request while access is pending.
- Persist checksums, matched version/confidence, disc ID, offset, drive identity, attempts and status in internal session evidence. Session settings retain verification preferences and drive profiles.
- Resolve drive vendor/model/firmware through IOKit; never persist serial numbers. Unknown identities do not inherit another drive's offset. Known offsets can be entered manually and are passed to `cd-paranoia -O`.
- Offset-finding checksums provide diagnostic candidates only. They do not automatically calibrate a drive. Cross-pressing reconstruction and automatic multi-disc calibration are not implemented.
- Rereads use fresh full-paranoia processes, abort-on-skip and no forced disc-edge overread. This alone does not establish cache-independent reads. Identical rereads without a reference are not reported as AccurateRip verified.
- Failed mismatch attempts retain their WAVs, including when a later attempt matches. The delete-WAV preference applies to the successfully converted attempt. Disc-edge samples excluded from the algorithm are not independently verified.

## Validation and remaining work

Synthetic tests cover checksum overflow/endianness/physical boundaries, TOC identity, malformed records, match confidence, missing references, HTTP failures, access gating, old session decoding, WAV validation and pipeline retry/conversion/recovery behavior. Pipeline tests use fake drive and encoder services; they do not establish hardware or codec correctness.

An opt-in test accepts the independent libarcstk `calculation-test-01.bin` reference via `CDRIP_AR_REFERENCE_PCM`; the reference binary is not included in the repository. Expected full-buffer values are v1 `8FE8D29B`, v2 `D15BB487`.

Before online release: obtain access approval, verify live transport compatibility, validate against known discs and calibrated physical drives, test different pressings and damaged media, and complete cancellation/remount hardware checks. No database access or new physical-disc validation has been performed for this change.

## Sources

- [AccurateRip third-party access policy](https://www.accuraterip.com/3rdparty-access.htm)
- [Official disc identifiers, record layout and CRC convention](https://forum.dbpoweramp.com/forum/other-topics/developers-corner/20117-accuraterip-crc-calculation)
- [Independent libarcstk reference tests](https://github.com/crf8472/libarcstk/blob/master/test/src/accuraterip.cpp)
