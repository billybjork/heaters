# Deep Research Prompt: Heaters — Technical & Product Strategy

> Copy everything below this line into a deep research session.

---

I'm the solo developer of **Heaters**, a video curation and semantic retrieval system. I need a comprehensive research report to guide the next phase of development — both the technical roadmap and the product/business strategy. Below is full context on what exists today and where it's pointed; after that, the specific research areas.

## Project Context

### What Heaters is

Heaters ingests videos (web-scraped via yt-dlp with a 4K/8K quality-first strategy, plus direct user uploads), runs them through an automated pipeline — download → H.264 all-I proxy encoding → OpenCV scene detection → cut points — and presents the resulting clips in a keyboard-driven human review UI. The core architectural innovation is a **cuts-based virtual clip model**: cut points define clips as *data*; no physical clip files exist until export. Review operations (approve, skip, archive, merge, group, frame-accurate split) are instant database operations, and export is 10x faster via FFmpeg stream copy. Approved clips flow through export → keyframe extraction → embedding generation (currently OpenAI CLIP via ONNX Runtime) → pgvector storage, with a similarity-search UI (pick an anchor clip, browse nearest neighbors).

### The mission

The end goal is a **motion-aware semantic retrieval system for action-sports footage — starting with snowboarding tricks** ("trick2vec"). A backside 540 and a frontside 540 look identical in any single frame; the difference is the spatiotemporal trajectory, so image embeddings (CLIP) are a stopgap. The committed plan (see below) is:

1. Swap in a **frozen V-JEPA 2 video encoder** (Meta's self-supervised video model) for motion-aware clip embeddings.
2. Train a **lightweight learned retrieval head** on top of frozen features, supervised by human similarity judgments collected through an anchor + 8–12 candidate ranking UI ("clip sorting events" — listwise ranking as primary objective).
3. Build a **trick ontology / structured metadata layer** for faceted and lexical search (with synonym normalization: "bs 540", "cab 5", etc.) — shipped *before* any video-text embedding.
4. Later: a separate **text-alignment head** trained only on curated language (canonical trick names, cluster labels, real query logs) enabling queries like "like this clip + backside 540".

The philosophy is explicitly Bitter-Lesson-aligned: no hand-coded trick classifiers, no rule-based physics; general pretrained models + human-judgment-trained retrieval geometry, with domain knowledge confined to the metadata/ontology layer.

### Technical stack and constraints

- **Backend**: Elixir/Phoenix 1.8, LiveView 1.1 (colocated hooks, minimal JS, no Tailwind, URL-first state). Strong architecture discipline: "I/O at the edges," declarative pipeline config, idempotent Oban workers, structured result types, Ecto enums + DB constraints.
- **Data**: PostgreSQL + pgvector. Embeddings upserted on `(clip_id, model_name, generation_strategy)`.
- **Media**: Native Elixir FFmpeg orchestration; temp-cache system that cut S3 I/O ~78%; S3 + CloudFront with signed URLs, HTTP range streaming for frame-accurate review playback.
- **Python**: deliberately minimal sidecar (yt-dlp download config, OpenCV scene detection, ONNX CLIP embedding) invoked via a file-based RPC protocol; `uv`-managed.
- **Deployment**: Docker on Render (web + optional worker service split via Oban queues). Fly.io + FLAME elastic compute is planned-but-not-active. No GPU anywhere yet.
- **Team & budget**: one solo developer, hobbyist/bootstrap budget, strong Elixir preference, ~1 year of part-time development in bursts. The pipeline works end-to-end; the retrieval-head training loop, sorting/labeling UI, metadata layer, and any V-JEPA 2 integration are **not yet built**.

## Research Areas

Research each of the following. For every area: give the current state of the art / market as of now, cite sources, name concrete options with trade-offs, and end with a specific recommendation for *this* project given the solo-developer constraint. Where my existing plan looks wrong or outdated, say so directly.

### Part 1 — Technical

1. **Video embedding models (current landscape).** My plan bets on V-JEPA 2 (June 2025). What has been released or benchmarked since? Compare current best open-weight video encoders for motion-centric similarity retrieval (V-JEPA 2 and successors, InternVideo, VideoPrism availability changes, VideoMAE lineage, any new self-supervised video models, and commercial APIs like Twelve Labs). Is frozen-backbone + learned-head still the right paradigm, and which checkpoint/size is the practical sweet spot for a solo dev embedding tens of thousands of ~2–15s clips?

2. **Learning retrieval from human judgments.** Best current practice for training a retrieval/projection head on frozen video features with hundreds-to-low-thousands of listwise human judgments: loss functions (listwise vs triplet vs contrastive), embedding dimensionality, active learning / candidate-selection strategies to maximize label efficiency, eval methodology (Recall@K, NDCG, human preference tests), and how to avoid confounders (same rider/spot/camera clustering instead of same trick). Are there open datasets or pretrained heads for action-sports/trick recognition worth bootstrapping from (e.g., skateboarding trick datasets, FineGym-style fine-grained action datasets)?

3. **GPU strategy for a solo developer.** Cheapest reliable path to (a) one-time backfill of video embeddings over an existing clip library, (b) ongoing incremental embedding of new clips, (c) frequent cheap retraining of a small retrieval head. Compare serverless/burst GPU options (Modal, RunPod, Replicate, Fly.io GPUs, Lambda, vast.ai) and whether FLAME on Fly fits this, vs. a local consumer GPU. Include realistic cost estimates per 1,000 clips embedded with a ViT-L video encoder.

4. **Vector search architecture.** Is pgvector (with HNSW) sufficient at 10k–1M clip scale, and what are current best practices (quantization, hybrid lexical+vector queries in Postgres, reranking)? At what point, if ever, would a dedicated vector DB pay off? How to store raw backbone embeddings vs. reprojected retrieval embeddings so head retraining doesn't require recomputing the backbone.

5. **Elixir-native ML vs. Python sidecar.** Evaluate Nx/Bumblebee/Ortex maturity for running video-model inference on the BEAM vs. keeping the current Python RPC pattern. Also: current state of FLAME for bursty media/ML workloads, and whether the planned Render → Fly migration is still the right call.

6. **Reducing the human review bottleneck.** Scene detection quality is the gate on everything downstream. Compare current shot-boundary/scene-detection models (TransNet V2, PySceneDetect algorithms, newer ML approaches) against OpenCV histogram methods, and research semi-automated review: can embeddings + a small classifier pre-sort obvious approves/rejects, auto-suggest merges, or rank the review queue by uncertainty so human time goes where it matters most?

7. **Ingestion risk.** The pipeline leans on yt-dlp scraping of platform video. Assess the technical fragility (platform countermeasures, maintenance burden) and the legal exposure of scraped footage in a personal-use tool vs. any future public or commercial product (YouTube ToS, copyright, fair use for ML training and for republication, DMCA posture). What ingestion strategies do comparable products use instead (creator uploads, licensing, platform APIs)?

### Part 2 — Product, Market, and Go-to-Market

8. **Who is this for? Map the plausible product directions and their markets:**
   - Personal media library / "second brain" for video editors and filmers
   - Community clip database + trick search for a niche (snowboarding first) — a "genius.com / chess-opening-explorer for tricks"
   - Pro tool for action-sports videographers and edit-makers (footage organization, montage assembly)
   - B2B: footage licensing marketplaces, brands/teams searching athlete footage, broadcast highlight retrieval
   - API/infrastructure: video-similarity search as a service
   For each: market size signal, willingness to pay, competition, and fit with what's already built.

9. **Competitive landscape.** Survey adjacent products and how they position: video AI search (Twelve Labs, Google/AWS video intelligence), clip-focused editor tools (Opus Clip, Klap, Descript), media asset managers (Frame.io, Eagle, Iconik, Kino/Tator), footage marketplaces (Filmsupply, Artgrid, Storyblocks), sports-tech video (Hudl, Veo), and anything snowboard/skate-specific (trick recognition apps, Carv-style products, community edit platforms like Newschoolers). Where is the open gap that a motion-aware, niche-first clip retrieval product could own?

10. **Viral and community features.** The retrieval-head training loop *needs* human similarity judgments — research how to turn labeling into engagement rather than toil. Precedents: gamified labeling (GeoGuessr-style daily challenges, "which clip is most similar?", chess puzzle apps, Wordle mechanics), community-curated knowledge bases (Genius, MusicBrainz, chess opening explorers), and shareable artifacts (embeddable "clips like this" pages, auto-generated trick lineage/mixtapes, "trick genome" visualizations). Which mechanics have actually worked for niche sports communities, and what would a labeling-as-game MVP look like?

11. **Go-to-market for a niche-first solo product.** Beachhead strategy in snowboarding: which communities matter (forums, subreddits, Discords, filmer/editor circles, brand/team media managers), what content-marketing angles fit (e.g., publishing trick-similarity maps, "every backside 540 in X video part"), whether an open-source or open-data angle helps, waitlist vs. build-in-public, and realistic paths from single-player utility → community network effects. Include cautionary tales of niche sports apps that failed and why.

12. **Business model and sequencing.** Given all the above: which monetization paths fit (prosumer subscription, marketplace take-rate, B2B API, licensing data/labels), what the realistic sequencing is for a solo dev (what to build/validate in the next 3, 6, 12 months), and what the cheapest falsifiable test of demand looks like before more infrastructure gets built.

### Part 3 — Synthesis

13. Close with: (a) a prioritized 6-month roadmap recommendation combining the technical and product findings, (b) the top 5 risks to the project as currently conceived, and (c) the 3 decisions I should make *now* that most constrain everything downstream.

## Output format

A structured report ordered by the numbered areas above. Lead each area with a 2–3 sentence bottom-line-up-front, then supporting detail with citations. Flag anywhere the evidence is thin or the answer genuinely uncertain rather than papering over it. Where my existing V-JEPA 2 plan conflicts with what you find, call it out explicitly in a dedicated "corrections to the current plan" list.
