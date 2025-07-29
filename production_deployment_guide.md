# Production Deployment Guide

## Overview

This guide covers deploying the Heaters video processing system with server-side FFmpeg streaming to production infrastructure. The system is architected for scalable, cost-effective deployment using Fly.io, CloudFront, and optional FLAME serverless patterns.

## Current Architecture Status

**✅ Development Complete:**
- Server-side FFmpeg time segmentation with process pooling and rate limiting
- Virtual clip streaming with database-level MECE constraints
- StreamingVideoPlayer frontend with 0-based timeline experience
- Performance monitoring and keyframe leakage detection
- Type-safe URL generation with cache versioning

**🚀 Ready for Production:**
- Phoenix app serves as custom origin for CloudFront
- FFmpeg streams exact clip ranges (no full video downloads)
- Each virtual clip feels like a standalone video file
- Comprehensive error handling and process cleanup

---

## Infrastructure Components

### **Core Architecture**

```
Browser → CloudFront (Global Cache) → Phoenix App (Fly.io) → FFmpeg Process Pool
                                           ↓
                                     S3 Proxy Files (Range Requests)
```

### **Key Technologies**
- **Application**: Phoenix LiveView on Fly.io
- **CDN**: AWS CloudFront (caches FFmpeg output globally)
- **Storage**: AWS S3 (proxy files, direct access via presigned URLs)
- **Database**: PostgreSQL with MECE constraints
- **Processing**: Server-side FFmpeg with process pooling

---

## Deployment Phases

### **Phase 1: Basic Production Deployment**

**Fly.io Application Setup:**
1. **Machine Configuration**:
   - Use `shared-cpu-1x` or `shared-cpu-2x` for development/staging
   - Consider `dedicated-cpu-1x` for production traffic
   - Ensure FFmpeg is available in the Docker image

2. **Environment Variables**:
   ```bash
   fly secrets set DATABASE_URL="postgresql://..."
   fly secrets set SECRET_KEY_BASE="..."
   fly secrets set AWS_ACCESS_KEY_ID="..."
   fly secrets set AWS_SECRET_ACCESS_KEY="..."
   fly secrets set S3_BUCKET="heaters-production"
   fly secrets set CLOUDFRONT_DOMAIN="your-distribution.cloudfront.net"
   ```

3. **Dockerfile Optimization**:
   ```dockerfile
   FROM flyio/elixir:1.16-slim
   RUN apt-get update && apt-get install -y ffmpeg --no-install-recommends
   # ... rest of Phoenix build
   ```

**CloudFront Distribution Setup:**

1. **Create Distribution**:
   - **Origin Domain**: `your-app.fly.dev`
   - **Origin Protocol**: HTTPS only
   - **Origin Path**: Leave empty

2. **Cache Behavior for Streaming**:
   - **Path Pattern**: `/videos/clips/*/stream*`
   - **Cache Policy**: `CachingOptimized` (handles Range headers)
   - **Origin Request Policy**: `CORS-S3Origin` (for CORS headers)
   - **Allowed Methods**: `GET, HEAD`
   - **TTL**: Use default (respects cache headers from Phoenix)

3. **Cache Behavior for Static Assets**:
   - **Path Pattern**: `/assets/*`
   - **Cache Policy**: `CachingOptimized`
   - **TTL**: 1 year (static assets are versioned)

**Database Configuration:**
- Ensure MECE constraints are applied (migration `20250728234518_add_mece_overlap_constraints.exs`)
- Consider read replicas for clip metadata queries at scale
- Connection pooling optimized for Fly.io networking

### **Phase 2: Performance Optimization**

**Monitoring Setup:**
1. **Application Metrics**:
   ```elixir
   # Monitor FFmpeg process utilization
   HeatersWeb.FFmpegPool.detailed_status()
   
   # Returns:
   # %{
   #   active_processes: 3,
   #   max_processes: 10,
   #   utilization_percent: 30.0,
   #   memory_usage: %{total_memory_mb: 45.2, process_count: 3}
   # }
   ```

2. **CloudFront Cache Monitoring**:
   - Set up CloudWatch alarms for cache hit ratios
   - Monitor origin request counts (should decrease over time)
   - Track egress bandwidth costs

3. **Application Logging**:
   - FFmpeg stream completion times are logged automatically
   - Keyframe leakage detection logs (currently for monitoring only)
   - Process pool utilization tracking

**Configuration Tuning:**
```elixir
# config/prod.exs
config :heaters, HeatersWeb.FFmpegPool,
  max_concurrent_processes: 15,  # Adjust based on machine resources
  cleanup_interval: 30_000

# Streaming timeouts for large clips
config :heaters, HeatersWeb.StreamPorts,
  stream_timeout: 300_000  # 5 minutes
```

**Regional Optimization:**
- Co-locate Fly.io machines with S3 bucket regions
- Consider multiple Fly.io regions for global performance
- Use S3 Transfer Acceleration if needed

### **Phase 3: 🔥 FLAME Serverless Architecture (Optional)**

**Cost Optimization Target:**
- Current: ~$5-20/month (always-on Phoenix)
- FLAME: ~$0.50/month (scale-to-zero, pay-per-use)

**FLAME Integration Components:**

1. **FLAME Runners** (`lib/heaters/flame_runners/`):
   ```elixir
   defmodule Heaters.FLAMERunners.FfmpegRunner do
     use FLAME.Runner
     
     def stream_clip(clip_id, signed_url) do
       # FFmpeg processing in ephemeral machine
       # Returns streaming data
     end
   end
   ```

2. **Architecture Changes**:
   - Replace `FFmpegPool` with `FLAME.call(FfmpegRunner, ...)`
   - Remove ETS-based process counting (use Fly machine limits)
   - Optimize for ~5-minute machine lifecycle
   - Ensure graceful shutdown coordination

3. **Benefits**:
   - **Zero Idle Cost**: Machines shutdown when not streaming
   - **Elastic Scaling**: Handle traffic spikes without provisioning
   - **Cost Efficiency**: Pay only for actual compute seconds
   - **CloudFront Caching**: High cache hit ratios minimize compute costs

---

## Performance Characteristics

### **Expected Metrics**
- **FFmpeg Startup Latency**: ~150ms (includes process spawn + input seeking)
- **Stream Copy Performance**: ~10ms per second of video content
- **Memory Usage**: ~15MB per active FFmpeg process
- **CPU Usage**: <10% per stream on shared-cpu-1x machines
- **Bandwidth Efficiency**: 90% reduction vs full-video streaming

### **Scaling Considerations**
- **Concurrent Streams**: 10-15 per shared-cpu-1x machine
- **CloudFront Caching**: Identical clips served globally without origin requests
- **Database Load**: Minimal (simple clip metadata queries)
- **S3 Costs**: Primarily GET requests and bandwidth for proxy files

### **Rate Limiting**
- Built-in FFmpeg process pool prevents resource exhaustion
- Returns 429 status when max concurrent processes exceeded
- CloudFront provides additional request rate limiting if needed

---

## Security Configuration

### **Authentication & Authorization**
- Streaming endpoints use existing Phoenix session authentication
- Consider short-lived HMAC tokens for direct CloudFront access
- Keep preview thumbnails public to reduce signing overhead

### **Network Security**
- All FFmpeg input via signed CloudFront URLs (not direct S3)
- HTTPS-only for all video streaming endpoints
- CORS headers configured via CloudFront origin request policy

### **Process Security**
- FFmpeg process isolation with `Port.monitor/1`
- Zombie process prevention with proper cleanup
- Resource limits enforced via ETS counters

---

## Cost Analysis

### **Current Architecture (Always-On Phoenix)**
- **Compute**: $5-20/month (Fly.io shared-cpu machines)
- **Storage**: S3 Standard pricing for proxy files
- **Bandwidth**: CloudFront egress costs (primary expense)
- **Database**: Minimal (simple queries, small dataset)

### **FLAME Architecture (Scale-to-Zero)**
- **Compute**: ~$0.50/month (pay per actual streaming time)
- **Storage**: Same S3 costs
- **Bandwidth**: Same CloudFront costs (caching reduces origin load)
- **Total Savings**: 80-90% on compute costs

### **Cost Optimization Strategies**
1. **High CloudFront Cache Hit Ratios**: Most requests served from edge
2. **Efficient FFmpeg Commands**: Stream copy vs re-encoding
3. **S3 Regional Alignment**: Minimize cross-region transfer costs
4. **Proxy File Strategy**: Dual-purpose for review and export

---

## Deployment Checklist

### **Pre-Deployment**
- [ ] FFmpeg available in Docker image
- [ ] Database MECE constraints applied
- [ ] Environment variables configured
- [ ] S3 bucket and CloudFront distribution created
- [ ] DNS configured for custom domain (optional)

### **Initial Deployment**
- [ ] Deploy Phoenix app to Fly.io
- [ ] Configure CloudFront origin and cache behaviors
- [ ] Test streaming endpoints with curl/browser
- [ ] Verify FFmpeg process pool monitoring
- [ ] Check CloudFront cache hit/miss ratios

### **Production Monitoring**
- [ ] Set up CloudWatch alarms for CloudFront metrics
- [ ] Monitor application logs for FFmpeg performance
- [ ] Track database constraint violations
- [ ] Monitor S3 request patterns and costs
- [ ] Set up alerting for 429 rate limiting responses

### **Optional FLAME Migration**
- [ ] Implement FLAME runners for FFmpeg processing
- [ ] Test ephemeral machine lifecycle management
- [ ] Migrate process pool logic to FLAME patterns
- [ ] Monitor cost savings and performance impact
- [ ] Implement graceful fallback to always-on if needed

---

## Troubleshooting Guide

### **Common Issues**

**FFmpeg Process Issues:**
- Check `HeatersWeb.FFmpegPool.detailed_status()` for utilization
- Monitor memory usage growth over time
- Verify zombie process cleanup in logs

**CloudFront Caching Issues:**
- Ensure cache policy supports Range headers
- Check cache-control headers from Phoenix responses
- Verify URL versioning for cache busting

**Performance Issues:**
- Monitor FFmpeg startup latency in logs
- Check S3 request patterns for efficiency
- Verify database query performance for clip lookups

**Cost Issues:**
- Analyze CloudFront bandwidth vs cache hit ratios
- Review S3 request patterns and pricing tier
- Consider FLAME migration for significant cost reduction

### **Diagnostic Commands**
```bash
# Check FFmpeg processes
fly ssh console -c "ps aux | grep ffmpeg"

# Monitor resource usage
fly ssh console -c "top"

# View application logs
fly logs --app your-app-name

# Test streaming endpoint
curl -I https://your-domain/videos/clips/123/stream/v1
```

---

## Future Enhancements

### **Immediate Opportunities**
- Cut point manipulation UI with instant streaming updates
- CloudFront cache warming for popular clips
- Advanced keyframe leakage handling (precision mode)
- Multi-region deployment for global performance

### **Advanced Features**
- Sequential clip playback (foundation already implemented)
- Real-time clip collaboration with LiveView
- Advanced performance analytics and optimization
- Integration with video analytics and ML pipelines

---

## Support & Maintenance

### **Regular Maintenance Tasks**
- Monitor CloudFront cost trends and optimization opportunities
- Review FFmpeg process pool configuration based on usage patterns
- Update Docker images for security patches
- Analyze database performance and query optimization

### **Scaling Considerations**
- FLAME migration becomes more cost-effective at higher usage
- Consider dedicated CPU machines for consistent performance
- Multi-region deployment for global user base
- Advanced caching strategies for frequently accessed clips

This deployment guide provides a clear path from development to production, with optional optimization phases based on usage patterns and cost requirements.