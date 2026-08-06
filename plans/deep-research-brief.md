# Deep Research Brief: Guiding Heaters' Development

**Purpose**: This document is the input for a dedicated deep-research session. It has two parts:

1. **Mission context** — a distilled audit of this repository (code, docs, plans, git history) so the research session doesn't need to re-derive what Heaters is.
2. **The research task** — the areas to investigate, concrete questions to answer, signal sources to mine, and the expected deliverable.

---

## Part 1: Mission Context (from repository audit, 2026-08-06)

### What Heaters is

Heaters is a video clip curation and semantic retrieval system. It ingests full-length videos (web-scraped via yt-dlp or user-uploaded), automatically detects scene boundaries, presents candidate clips to a human reviewer in a fast keyboard-driven interface, exports approved clips losslessly, embeds them into a vector space, and supports "find clips like this" similarity search.

The name is action-sports slang: a "heater" is an exceptional clip/trick. The domain focus — explicit in `plans/v-jepa2-embedding-pipeline.md` — is **snowboarding trick footage**: distinguishing a backside 540 from a frontside 540, grab types, terrain features, style. The plan repeatedly frames the goal as **"trick2vec"**: a learned embedding space where clips cluster by *skill/trick similarity* (same trick, different riders/spots) rather than visual similarity (same snow color, same camera angle).

### The core technical insight already built

**Cuts-based virtual clips**: cut points are data, clips are derived entities between cuts, with no physical files until export. Review operations (split, merge, move cut) are instant database operations with zero re-encoding. Export uses FFmpeg stream copy from an all-I H.264 proxy (~10x faster than re-encoding, preserves quality). This is a genuinely differentiated ingestion/curation engine.

### Current pipeline

```
Source video: new → downloading → downloaded → encoding → encoded → detect_scenes → cuts created
Clips: pending_review → review_approved → exporting → exported → keyframing → keyframed → embedding → embedded
Review actions: approve / skip / archive / merge / group / split (frame-accurate, hotkey-driven)
```

- **Stack**: Elixir/Phoenix 1.8 + LiveView 1.1, PostgreSQL + pgvector, Oban job orchestration, native FFmpeg execution, minimal Python sidecar (yt-dlp assist, OpenCV scene detection, ONNX Runtime CLIP embeddings), S3 + CloudFront, Docker; Bun for JS, uv for Python.
- **UI surfaces**: `/review` (clip review queue with frame-accurate split mode), `/query` (embedding nearest-neighbor exploration), `/submit_video` (URL submission). The home page is still the default Phoenix placeholder.
- **No auth, no users table, no multi-tenancy** — this is a single-operator internal tool today.
- **Deployment**: targets Render (single app image + Postgres); Fly.io + FLAME for elastic media workers is documented as future architecture. No GPU infrastructure yet.

### Where it's headed (per the V-JEPA 2 plan, refined 2026-03-10)

A **multi-layer retrieval system**, explicitly *not* one embedding for every job:

- Frozen **V-JEPA 2** video encoder (Meta, self-supervised, SOTA motion understanding) as the base representation — replacing image-level CLIP keyframe embeddings, because motion *is* the signal for tricks.
- A lightweight **learned retrieval head** trained on human similarity judgments, collected via an anchor + 8–12 candidates ranking UI (append-only judgment event log; listwise ranking loss).
- A separate **structured metadata / trick-ontology layer** for reliable text and faceted search (synonym normalization: "bs 540", "cab 5"), shipped *before* any video–text embedding.
- A later **text-alignment head** trained only on curated language — explicitly not on auto-captions.
- Bitter-lesson alignment: no hand-coded trick classifiers; domain knowledge enters only through the ontology/metadata layer and labeling workflow design.

Not yet built: the sorting/judgment UI, retrieval-head training loop, metadata/faceted search layer, text alignment, GPU strategy for V-JEPA 2 inference.

### Development history & cadence (signal about the builder)

- **May–Aug 2025**: intense solo build — schema, pipeline, virtual clips, review UI, export, keyframes, embeddings; end-to-end workflow working by mid-August 2025.
- **Sep 2025 – Jan 2026**: hiatus (~5 months, no commits).
- **Jan–Mar 2026**: resumed with heavy code-quality, tooling, and infrastructure modernization (uv, Bun, ONNX, native Elixir download, Elixir↔Python RPC hardening), largely via Claude-assisted PRs; culminating in the refined V-JEPA 2 retrieval plan (last commit 2026-03-10).
- **Today (2026-08-06)**: ~5 months since the last commit. The project is at an inflection point: the ingestion/curation engine is solid, the ML retrieval direction is well-thought-out but unimplemented, and there is **no product layer, no defined user, no distribution strategy**.

### What the repository does NOT answer (the gap this research must fill)

- **Who is this for?** Single-operator archive tool? Consumer app for riders/filmers? B2B tool for media companies, brands, event producers? A community platform? The repo is silent.
- **What's the business/distribution model?** Nothing exists: no landing page, no auth, no pricing, no marketing.
- **Why snowboarding, and is it a wedge or the endgame?** Action-sports-generally (skate, surf, MTB, ski) is a natural adjacency; so is the general "semantic search over personal/organizational video archives" market.
- **What would make it spread?** No viral or social mechanics exist or are planned.

These are the open questions the deep-research session must ground in external evidence.

---

## Part 2: The Deep Research Task

**Mission for the research session**: Produce an evidence-based strategy report that guides Heaters' next 6–12 months across (a) technical architecture, (b) product definition, (c) market positioning and go-to-market, and (d) growth/viral mechanics. Analyze all available external signals: companies, existing apps, people, videos, discussion forums, academic papers, open-source code, funding/M&A activity, and platform trends.

Use web search and fetches extensively. Prefer primary sources (papers, repos, app store listings, forum threads, creator content) over listicles. Date-stamp findings — the video-AI space moves fast and anything pre-2025 may be stale. Where evidence is thin, say so explicitly rather than extrapolating.

### Area A: Technical research

1. **Video embedding & retrieval state of the art (2025–2026)**
   - Validate or challenge the V-JEPA 2 choice: what has shipped since the plan was written (2026-03)? Successors (V-JEPA 3?), competing video encoders (InternVideo 2.5/3, VideoPrism availability changes, Qwen-VL video, apple/google releases), fine-grained action-recognition results on SSv2/FineGym/Epic-Kitchens.
   - Research on **fine-grained action retrieval / sports action recognition** specifically: skating/snowboarding/gymnastics trick classification papers and datasets (e.g., FineGym, Diving48, anything action-sports-specific), pose-estimation-augmented retrieval, temporal localization of action highlights.
   - Practicality of learned retrieval heads on frozen video features with hundreds-to-thousands of human judgments: published results, label-efficiency techniques, active learning for retrieval.
2. **Inference & infrastructure economics**
   - Realistic GPU strategy for a solo/bootstrap project: cost per 1k clips embedded with V-JEPA 2 ViT-L/H on Modal/Replicate/RunPod/Fly GPU/batch pipelines; serverless GPU cold-start realities; ONNX/quantization options for video transformers.
   - Whether Fly.io + FLAME is still the right elastic-compute bet for Elixir in 2026, vs. alternatives (Oban Pro + plain autoscaling, separate GPU microservice).
3. **Scene detection & highlight detection**
   - Current best open tooling vs. the existing OpenCV approach (PySceneDetect vs. TransNetV2 vs. newer models); automatic *highlight* detection (trick attempt vs. filler) to reduce human review load — papers, models, and what sports-video products actually use.
4. **Automated trick metadata extraction**
   - VLM capabilities (2026) for labeling trick attributes from clips (rotation, stance, grab, terrain): can current video-capable LLMs bootstrap the metadata layer cheaply? Accuracy evidence on fine-grained sports actions; cost per clip.
5. **Comparable open-source systems**
   - Study architectures of open-source video search/curation projects (e.g., anything comparable on GitHub: video semantic search, media asset managers, Jellyfin/Immich-style ecosystems adding vector search) for both technical ideas and evidence of demand.

### Area B: Product & competitive landscape

1. **Direct/adjacent products** — for each: what it does, target user, pricing, traction signals (app-store ranks, reviews, community chatter), and what Heaters could learn or must differentiate against:
   - Action-sports clip apps and auto-editors (historical and current: e.g., Shred/WeShred-type apps, GoPro Quik, Insta360 app auto-edit, CapCut templates, Hyperlapse-era graveyard — why did prior action-sports clip apps die?).
   - Sports video analysis platforms (Hudl, Veo, Trace, OnForm, CoachNow) — especially any moving into action sports or semantic search.
   - AI video search / media asset management (Twelve Labs, Vidrovr, Coactive, Moments Lab, Jumper.video, Eagle, Adobe's semantic search) — the "search your footage" market: pricing, customers, positioning.
   - Footage licensing / UGC marketplaces (Storyful, Jukin/Trusted Media Brands, Catalog/museum-style archives, stock platforms adding vector search) — is "curated action-sports clip archive" itself a monetizable asset?
2. **User & workflow research** — who actually has this problem?
   - Filmers/editors in snowboarding (video-part culture, "full part" workflows), park crews, brands/team managers, event media teams, coaches, everyday riders with GoPro dumps. What do they use today (Premiere bins, Finder folders, LumaFusion, Frame.io)? Mine forum/Reddit/Discord threads (r/snowboarding, r/videoediting, Newschoolers, Slush forums, filmmaker Discords) for expressed pain about footage organization and finding clips.
3. **Positioning options to evaluate with evidence** (not to decide a priori):
   - (a) Personal "trick memory" tool for riders/filmers; (b) prosumer archive/search for filmers & brands; (c) B2B media-asset search for action-sports publishers; (d) community trick database/platform ("every backside 540 ever filmed"); (e) dataset/licensing play. For each: market size proxies, willingness-to-pay evidence, competition, and fit with what's already built (solo-operator curation engine with human-in-the-loop quality).

### Area C: Marketing & go-to-market

1. How comparable niche prosumer tools reached their first 1k users (e.g., how Eagle, Raycast-style tools, niche sports apps grew): channels that actually worked in adjacent cases.
2. The snowboard/action-sports media ecosystem as a distribution channel: key creators, filmers, publications (Torment, Slush, Whitelines successors), podcasts, YouTube/TikTok/IG accounts built on trick clips and compilations; who curates clips today and how they source them.
3. Timing/seasonality (Northern-hemisphere season Nov–Apr; product launch windows around season start, X Games, Olympics 2030 cycle, video-part drop season).
4. Community-led growth patterns: open-source as marketing (given the codebase could be public), Discord-first communities, "build in public" in the sports-tech niche.

### Area D: Viral & social feature candidates

Research precedents and evidence for features like:
- "Find every clip of this trick" public search (SEO/shareability of trick pages, cf. chess opening explorers, Skatevideosite, dunk databases).
- Trick identification from an uploaded clip ("what trick is this?" — Shazam-for-tricks); evidence people ask this (forum thread frequency).
- Auto-generated "trick genealogy"/progression maps, rider trick coverage matrices (cf. "spreadsheet" culture in skateboarding — e.g., the Jonny Giger trick spreadsheet phenomenon), leaderboards, daily clip games (Wordle-pattern), best-of compilations with attribution.
- Clip battles / voting formats (cf. SLS Trick Battle, r/skateboarding clip contests) and rights/attribution pitfalls of scraped footage — research the legal/community-norm landscape for reposting trick clips with credit.

### Area E: People & prior art worth studying

- Founders/projects who built in this exact space (action-sports apps, sports-AI startups, video-search startups): what they shipped, what happened, post-mortems, interviews.
- Researchers active in fine-grained action understanding and video retrieval whose work (and code) could be leveraged or who signal where the field is going.

### Method & sources checklist

Sweep multiple modalities, not just web articles: app stores (reviews = pain-point gold), GitHub (stars/issues as demand signals), arXiv (2025–2026), Reddit/forums/Discords, YouTube (product demos, filmer workflow videos), Product Hunt/Hacker News launches and comment threads, Crunchbase/funding news, job postings (who's hiring for video-search = who's investing in it).

### Expected deliverable of the research session

A single strategy report (markdown, committed to `plans/`) containing:

1. **Executive summary** — the 5–10 findings that should most change what gets built next.
2. **Technical recommendations** — confirm/adjust the V-JEPA 2 plan with 2026 evidence; concrete GPU/cost plan; highlight-detection and VLM-metadata opportunities with expected effort/cost.
3. **Product thesis** — ranked positioning options with supporting evidence, a recommended primary user and wedge, and what minimal product surface that implies (auth? sharing? public pages?).
4. **GTM playbook sketch** — first-100/first-1k user channels with named communities, creators, and timing.
5. **Viral feature shortlist** — 3–5 candidates ranked by evidence of demand × feasibility on the existing engine.
6. **Risks & open questions** — including rights/licensing of scraped footage, platform dependency (yt-dlp fragility), and solo-founder scope hazards.
7. **Source appendix** — links, dated.

### Constraints & context to respect

- Solo builder, bootstrap economics; the existing Elixir/Phoenix + pgvector + S3 stack is a keeper, not up for debate.
- The human-in-the-loop curation engine is the moat-in-progress; recommendations should compound on it, not bypass it.
- The V-JEPA 2 plan (`plans/v-jepa2-embedding-pipeline.md`) is the current technical north star — research should stress-test it, not ignore it.
- Snowboarding is the beachhead domain; treat generalization (other action sports, general video archives) as an explicit research question, not an assumption.
