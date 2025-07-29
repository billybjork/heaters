# Heaters Video Workflow Inefficiency Report

Date: 2025-07-29

## Overview
This document highlights specific areas of inefficiency observed in the current video‑ingest pipeline (Elixir/Phoenix + Oban + Python) and suggests low‑complexity fixes suitable for a future FLAME deployment on Fly.io.

## Hot‑spots & Remedies

| Where the waste shows up | Why it’s costing you | Zero‑ or near‑zero‑complexity fix |
|---|---|---|
| **1. Upload → immediate download loop**  <br/>• `DownloadWorker` uploads the 4 MB file to S3, `PreprocessWorker` downloads it seconds later. <br/>• Same pattern with proxy files. | • S3 PUT, GET and egress charges. <br/>• Adds ~1 s latency per PUT/GET. | **Short‑circuit S3 inside the job chain**: <br/>a. Pass local temp path through Oban args. <br/>b. Upload only in final step. <br/>c. Mount small tmp volume in FLAME. |
| **2. Two FFmpeg passes for short MP4s** | • Double encode cost & disk writes. | Skip normalization when the original container is MP4/H.264 + AAC. |
| **3. FFV1 master balloons size** | • 4 MB clip becomes 50 MB. | Consider: <br/>• Rely on original + proxy; generate lossless master on‑demand, or <br/>• Use `-level 4 -slicecrc 0` to shrink. |
| **4. Scene detection repeats keyframe scan** | CPU repeat + 9 MB S3 GET. | Persist `keyframe_offsets` and pass to `DetectScenesWorker`. |
| **5. Per‑task Python Port spin‑up** | Additional 300 ms cold‑start each task. | Keep a small pool of long‑lived Python workers; send JSON commands. |
| **6. yt‑dlp PO‑token warnings** | Extra HTTP calls & noisy logs. | Pin yt‑dlp `2025.06.*` and pass extractor args once. |
| **7. Verbose S3 progress + verification HEAD** | 70 % of log volume. | Disable progress bars outside dev; skip extra HEAD for <10 MB uploads. |
| **8. Credentials printed in logs** | Security risk. | Mask `AWS_SECRET_ACCESS_KEY` before logging. |

## Tiny Implementation Sketch (Elixir)

```elixir
defp local_cache_path(%{"s3_key" => key} = attrs) do
  {:ok, tmp} = Temp.mkdir("heaters")
  local = Path.join(tmp, Path.basename(key))

  unless File.exists?(local) do
    Heaters.S3.download!(key, local)
  end

  Map.put(attrs, "local_path", local)
end
```

Use `Oban.insert/4` with updated args, and upload to S3 only once in the final worker or success hook.

---

### Expected Impact on Fly.io + FLAME

* **~2× cheaper** S3 egress and operation costs.
* Faster cold‑starts due to fewer Python forks and network calls.
* Controlled storage growth—no automatic 50 MB masters unless needed.

---
