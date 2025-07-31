# HTML5 Media Fragments Implementation Plan

## Executive Summary

This plan implements HTML5 Media Fragments (`#t=start,end`) for dynamic video clipping, replacing the nginx mp4 module approach. This leverages built-in browser behavior for byte-range streaming with zero additional infrastructure, eliminating all complex video processing while achieving sub-second clip playback.

**Key Insight:** Modern browsers automatically handle `video.mp4#t=12.5,18.7` URLs by making targeted byte-range requests to CloudFront, streaming only the necessary clip data.

## Why Media Fragments Works

### Browser Behavior (HTML5 Spec)
When loading `…/video.mp4#t=12.5,18.7`, every modern browser:
1. **GET range 0-1MB** → grabs `ftyp` and `moov` atoms  
2. **Computes byte offsets** for the time range
3. **GET range X-Y** → streams only the clip payload (typically few hundred KB)
4. **Starts playback at 0s** of fragment, keeping `.currentTime` offset-free

### CloudFront/S3 Behavior
- CloudFront forwards Range headers to S3 by default
- S3 supports multipart range requests (up to 5GB per part)
- Both ranges arrive quickly and are cacheable by CloudFront
- **Result:** 206 Partial Content responses, not 200 full-file downloads

### Prerequisites Verification ✅
- **Fast-start MP4s:** ✅ Confirmed `moov` atom at file start
- **Range request support:** ✅ CloudFront returns 206 Partial Content  
- **CORS headers:** ✅ Already configured for cross-origin requests
- **Accept-Ranges: bytes:** ✅ S3/CloudFront default behavior

## Implementation Plan

### Phase 1: Update VideoUrlHelper (5 minutes)

**File:** `lib/heaters_web/helpers/video_url_helper.ex`
**Task:** Replace nginx URLs with direct CloudFront + Media Fragments

```elixir
def get_video_url(%{is_virtual: true} = clip, source_video) do
  build_media_fragment_url(clip, source_video)
end

defp build_media_fragment_url(clip, source_video) do
  case source_video.proxy_filepath do
    nil -> {:error, "No proxy file available for virtual clip"}
    proxy_filepath ->
      s3_key = extract_s3_key(proxy_filepath)
      cloudfront_domain = Application.fetch_env!(:heaters, :cloudfront_domain)
      
      start = :erlang.float_to_binary(clip.start_time_seconds, decimals: 3)
      finish = :erlang.float_to_binary(clip.end_time_seconds, decimals: 3)
      
      url = "https://#{cloudfront_domain}/#{s3_key}#t=#{start},#{finish}"
      {:ok, url, :direct_s3}  # Tell JS it's a direct file
  end
end
```

### Phase 2: Optional UX Enhancement (2 minutes)

**File:** `assets/js/streaming-video-player.js`
**Task:** Reset timeline display to hide time offset

```javascript
handleLoadedMetadata() {
  if (this.playerType === 'direct_s3' && this.video.duration) {
    this.video.currentTime = 0;  // Hide original video's time offset in UI
  }
}
```

### Phase 3: Remove nginx Infrastructure (10 minutes)

#### 3.1 Remove nginx Service
**File:** `docker-compose.yaml`
**Task:** Remove entire nginx-mp4 service block

#### 3.2 Remove nginx Configuration  
**File:** `nginx/nginx.conf`
**Task:** Delete file entirely

#### 3.3 Remove nginx URL Config
**File:** `config/runtime.exs`
**Task:** Remove nginx_mp4_url configuration lines

### Phase 4: Testing and Validation (5 minutes)

#### 4.1 Browser Range Request Test
```bash
# Test Media Fragments in browser - should show two 206 responses
open "https://d3c6go2xqa5u0r.cloudfront.net/proxies/clip.mp4#t=35.463,39.963"

# DevTools → Network should show:
# 1. First 206: ~1-2MB (moov atom probe)  
# 2. Second 206: ~4-6MB (clip payload)
# No 200 responses, no full-file downloads
```

#### 4.2 Integration Test
```elixir
# Test URL generation in Elixir console
clip = Heaters.Repo.get(Heaters.Clips.Clip, 341) |> Heaters.Repo.preload(:source_video)
{:ok, url, :direct_s3} = HeatersWeb.VideoUrlHelper.get_video_url(clip, clip.source_video)
IO.puts("Generated URL: #{url}")
```

## Key Benefits

### Operational Simplicity
- **0 additional services** - Remove nginx container entirely
- **0 moving parts in BEAM** - No FFmpeg ports, no process pools
- **CDN-native** - 100% traffic is cache-friendly byte ranges
- **Standards-based** - Built into HTML5 Media Fragments spec

### Performance Improvements  
- **Sub-second startup** - Browser's optimized range requests
- **Minimal bandwidth** - Only streams necessary clip data
- **Perfect caching** - CloudFront caches both metadata and clip ranges
- **Unlimited concurrency** - No process pools or container limits

### Maintenance Benefits
- **Simplified architecture** - Remove nginx service + configuration
- **Fewer failure modes** - Eliminate nginx mp4 module complexity  
- **Standard browser behavior** - No custom video processing logic
- **Future-proof** - Media Fragments are W3C standard

## Files Modified

### Updated Files
- `lib/heaters_web/helpers/video_url_helper.ex` - Media Fragments URL generation
- `assets/js/streaming-video-player.js` - Optional timeline reset

### Removed Files  
- `docker-compose.yaml` - Remove nginx-mp4 service
- `nginx/nginx.conf` - Delete entirely
- `config/runtime.exs` - Remove nginx_mp4_url config
- `NGINX_IMPLEMENTATION_PLAN.md` - Superseded by this plan

### Unchanged Files (Key Benefit!)
- All LiveView components - Work identically with direct URLs
- `streaming-video-player.js` - Already supports `direct_s3` player type
- Frontend templates - No changes needed
- Database schema - Uses existing `proxy_filepath` field

## Implementation Timeline

- **Phase 1 (URL Helper)**: 5 minutes - Media Fragments URL generation
- **Phase 2 (UX Polish)**: 2 minutes - Optional timeline reset  
- **Phase 3 (Cleanup)**: 10 minutes - Remove nginx infrastructure
- **Phase 4 (Testing)**: 5 minutes - Browser validation
- **Total Implementation**: ~22 minutes

## Success Validation

### Expected Browser Behavior
1. **DevTools Network tab** shows exactly 2 requests:
   - First 206: 1-2MB (metadata probe)
   - Second 206: 4-6MB (clip payload) 
2. **Video starts immediately** at clip beginning (0 seconds)
3. **Scrub bar remains responsive** throughout clip duration
4. **Looping works perfectly** within clip boundaries

### Performance Expectations
- **Startup time**: Sub-second (vs 2-5 seconds with FFmpeg)
- **Bandwidth efficiency**: Only necessary bytes (vs full proxy downloads)
- **Concurrent capacity**: Browser/CloudFront limits (vs 10 FFmpeg processes)
- **Cache hit rates**: High (byte ranges are cacheable)

This approach provides the simplest possible implementation while leveraging standard browser capabilities for optimal performance and reliability.