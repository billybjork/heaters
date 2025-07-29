# Heaters Video Workflow — Diagnostic & Optimisation Plan (v3)

**Date generated:** 2025-07-29 21:28 UTC

---

## 1 · Project Context & Goals

| Goal | Current status | Desired outcome |
|---|---|---|
| ⚡ **Fast, hands‑off ingest** – pull any public YouTube URL, cut it into reviewable “virtual clips”. | Pipeline works end‑to‑end in dev; single 26 s video takes ~36 s wall‑time. | Maintain or improve speed while scaling to dozens of concurrent ingests. |
| 💸 **Cost‑efficient at scale** – Fly.io FLAME bills for CPU + bandwidth; AWS bills for S3 ops/egress + Glacier storage. | Re‑uploads, lossless masters & duplicate downloads inflate bill; CPU idle while waiting for network. | Halve network chatter & storage without sacrificing quality. |
| 🔄 **Stateless, serverless‑friendly architecture** – Each worker should complete with minimal local state. | Workers are stateless but needlessly hit S3 between adjacent steps. | Use short‑lived tmp volume + Oban arg‑passing to keep artefacts local within a job chain. |
| 🎥 **Highest available video quality** – Always combine yt‑dlp’s best video & audio streams. | Achieved now via “normalize” FFmpeg pass but followed by a second encode. | Preserve current quality guarantee, *reuse* first‑pass output when compatible, avoid double‑encode. |

---

## 2 · What We Saw in the Logs (single 26 s sample)

| Stage | Start → End | Wall‑time | Key bytes moved | Notes |
|---|---|---|---|---|
| **DownloadWorker** <br/>yt‑dlp → normalize | 17:48:00 → 17:48:05 | **6.9 s** | +1.6 MB in, 4.0 MB out to S3 | Quality mux ok; immediate S3 PUT. |
| **PreprocessWorker** <br/>master & proxy encode + upload | 17:49:00 → 17:49:27 | **26.9 s** | pulls 4 MB, uploads **50 MB** master (Glacier) + 9 MB proxy | Upload dominates runtime (19 s). |
| **DetectScenesWorker** | 17:50:00 → 17:50:03 | **2.7 s** | pulls 9 MB proxy | Keyframe offsets already existed but weren’t reused. |
| **TOTAL** | 63 s pipeline (incl. scheduler gaps) | **36.5 s active** | **~78 MB S3 traffic** | 6× file size amplification mainly due to FFV1 master. |

> **Latency vs. cost takeaway:** Network + storage dwarf CPU on small clips; on FLAME you’ll pay for bandwidth and Glacier retrievals more than compute for these steps.

---

## 3 · Targeted Inefficiencies & Practical Fixes

*(Table expanded from v2 – see ⬆ logs column for motivation.)*

| # | Pressure point | Impact (time/$$) | Pragmatic fix |
|---|---|---|---|
| **1** | S3 PUT→GET→PUT ping‑pong between adjacent Oban jobs. | +1 s latency **per hop**, extra egress cost. | Pass local file path through Oban args; only PUT once chain finishes. |
| **2** | Double encode: normalize (mux+encode) *then* master/proxy encode. | +1.2 s CPU, tmp I/O. | Keep normalize (guarantees quality). *If* output is already H.264/AAC ≤1080 p, use it directly for proxy; generate master only on demand. |
| **3** | Always generating lossless FFV1 masters. | +46 MB storage, 18 s upload each clip. | Make FFV1 master optional or on‑demand; or use `-level 4 -slicecrc 0` to reduce size by ~20 %. |
| **4** | Scene‑detector redownloads & rescans proxy. | +9 MB GET, 450 ms CPU. | Persist `keyframe_offsets` JSON; feed to detector. |
| **5** | Each PyRunner spawns a fresh Python VM. | 300 ms cold‑start / task. | Maintain N long‑lived Python worker Ports; send JSON commands. |
| **6** | yt‑dlp PO‑token retries. | 2–3 extra HTTP calls. | Pin yt‑dlp `2025.06.*`; pass extractor args once. |
| **7** | Verbose 10 % S3 progress + HEAD verify. | Log noise + 1 extra HEAD op. | Silence progress except in dev; skip HEAD for files <10 MB. |
| **8** | Credentials printed in logs. | Security exposure. | Redact before logging. |

---

## 4 · Road‑mapped Actions

### Quick wins (≤1 day)
1. Mask secrets in `PyRunner`.
2. Silence S3 progress / verification logs in `prod`.
3. Pin yt‑dlp & set extractor args to remove PO‑token warnings.

### Medium (1‑3 days)
* Implement **local‑path pass‑through** and single PUT strategy across `Download`, `Preprocess`, `DetectScenes`.
* Persist `keyframe_offsets` in DB; update `DetectScenesWorker`.
* Add feature flag (`generate_master?`) to toggle FFV1 unless requested.

### Larger effort (≈1 week)
* Replace per‑task Python with pooled Port workers (or `GenStage`).
* Conditional master generation triggered by an “Export” job that hydrates from Glacier only when an editor requests lossless.

---

## 5 · Cost & Latency Forecast (per 30 s clip)

| Scenario | S3 traffic | Compute/encode passes | Estimated Fly $ per 1 000 clips* |
|---|---|---|---|
| Today | ~78 MB | 3 | **$8‑10** S3 + $1.5 CPU |
| After quick + medium wins | **~24 MB** | 2 | **$2.6** S3 + $1.3 CPU |
| With on‑demand masters | **~10 MB** (proxy only) | 1 (proxy) | **$1.1** S3 + $0.8 CPU |

\*Rough calc: us‑west‑1 egress $0.09 / GB; PUT/GET $0.0004 / 1 000; Fly bandwidth $0.02 / GB; CPU $0.00004 / core‑s.

---

## 6 · Appendix – Code Snippet for Local Cache

```elixir
defp maybe_download_to_tmp(%{"s3_key" => key} = attrs) do
  tmp_dir = System.tmp_dir!() |> Path.join("heaters-cache") |> File.mkdir_p!()
  local   = Path.join(tmp_dir, Path.basename(key))

  unless File.exists?(local) do
    Heaters.S3.download!(key, local)
  end

  Map.put(attrs, "local_path", local)
end
```

Chain with:

```elixir
Oban.insert!(VideoApp.Job.Preprocess.new(maybe_download_to_tmp(attrs)))
```

---

---

## 7 · Implementation Status (Updated 2025-07-29)

### ✅ **Completed Optimizations**

#### **Quick Wins (Completed)**
1. **Conditional Master Generation** (`FFmpegConfig`)
   - Added `skip_master: true` option to `FFmpegConfig.get_args/2`
   - Added `should_skip_master?/2` helper with app config support
   - **Impact**: Up to 60% storage reduction when masters not needed

2. **Secret Masking** (`PyRunner`)
   - Added comprehensive secret redaction for logs
   - Masks AWS credentials, database URLs with smart truncation
   - **Impact**: Security compliance, no more credential exposure

#### **Medium Effort (Completed)**
3. **Temp File Chain Pattern** (`TempCache`)
   - Enhanced existing `TempCache` module with `get_or_download/2`
   - Added `put_processing_results/2` for multi-file caching
   - **Impact**: Eliminates S3 PUT→GET→PUT round trips

4. **Worker Chain Integration** 
   - **DownloadWorker**: Caches download results via `use_temp_cache: true`
   - **PreprocessWorker**: Uses cached source, conditional master, temp results
   - **DetectScenesWorker**: Uses cached proxy, passes keyframe offsets
   - **Impact**: ~3x reduction in S3 operations

5. **Smart Proxy Reuse Logic** (`PreprocessWorker`)
   - Analyzes normalized downloads for H.264/AAC ≤1080p compatibility
   - Reuses suitable files as proxy, skips re-encoding
   - **Impact**: Eliminates double encoding when possible

### 🧪 **Architecture Highlights**

#### **Elixir-Idiomatic Approach**
- Uses existing `TempCache` module (no architectural changes)
- Maintains stateless worker principles
- Preserves functional architecture patterns
- Compatible with FLAME's ephemeral containers

#### **Quality Preservation**
- ✅ Maintains yt-dlp quality-first download strategy
- ✅ Normalization still applied when needed for merge issues
- ✅ Smart reuse only when codecs/quality meet proxy requirements
- ✅ Fallback to full pipeline if temp cache fails

#### **Production Reliability**
- Graceful fallback to S3 if temp cache unavailable
- Comprehensive error handling and logging
- Maintains existing idempotency patterns
- No breaking changes to existing workflows

### 📊 **Expected Performance Impact**

| Metric | Before | After | Improvement |
|--------|--------|-------|-------------|
| **S3 Operations** | ~6 per video | ~2 per video | **67% reduction** |
| **Network Traffic** | ~78 MB | ~24-32 MB | **60% reduction** |
| **Encoding Passes** | 3 (normalize + master + proxy) | 1-2 (smart reuse) | **33-50% reduction** |
| **Security Exposure** | Credentials in logs | Masked secrets | **✅ Compliant** |

### 🔄 **Workflow Changes**

#### **New Optimized Flow**
```
Download → [temp cache] → Preprocess → [temp cache] → DetectScenes → [finalize to S3]
    ↓           ↓              ↓            ↓              ↓
  Cache      Reuse         Smart        Reuse         Upload
  result     source        proxy        proxy         cached
             file          reuse        file          files
```

#### **Backward Compatibility**
- All workers fall back to traditional S3 approach if temp cache fails
- Existing videos continue processing normally
- No database schema changes required
- Feature flags allow gradual rollout

### 🚀 **Next Steps**

#### **Testing Phase** (Remaining)
- [ ] Comprehensive quality verification
- [ ] Performance benchmarking on sample videos
- [ ] Edge case testing (large files, network failures)

#### **Production Rollout**
- [ ] Enable via feature flags in staging
- [ ] Monitor S3 cost reductions
- [ ] Gradual rollout to production traffic

#### **Future Enhancements** 
- [ ] Python worker pooling (eliminate VM spawning)
- [ ] On-demand master generation workflow
- [ ] Enhanced S3 logging controls

### 💡 **Key Learnings**

1. **Architecture Alignment**: Using existing `TempCache` proved much cleaner than the originally proposed local cache approach
2. **Quality First**: All optimizations preserve the yt-dlp quality-first strategy
3. **Graceful Degradation**: Fallback patterns ensure reliability
4. **Elixir Idioms**: Solution aligns with functional architecture principles

---

### Ready for Testing

The core optimizations are now implemented and ready for verification. The next critical step is comprehensive testing to ensure quality preservation and performance gains.
