/**
 * WebCodecs-based Video Player for Virtual Clips
 * ──────────────────────────────────────────────────────────────────────────
 * • WebCodecsPlayerController – Phoenix hook for virtual clip review
 * • WebCodecsPlayer           – core WebCodecs playback with frame seeking
 * • FallbackVideoPlayer       – traditional <video> fallback for older browsers
 *
 * Uses keyframe offsets for frame-perfect seeking on review proxy videos.
 * Automatic fallback to <video> element when WebCodecs is unavailable.
 */

export { WebCodecsPlayer } from "./webcodecs-player-core";
export { FallbackVideoPlayer } from "./fallback-video-player";
export { WebCodecsPlayerController } from "./webcodecs-player-controller"; 