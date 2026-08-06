# Deep Research Prompt: Heaters — Product, Market, and Technical Strategy

> Copy everything below this line into a deep research session.

---

## Context: What Heaters Is

I am the solo developer of **Heaters**, a video curation and semantic retrieval system for snowboarding clips ("heaters" = exceptional clips in rider slang). It is currently a personal internal tool, built on Elixir/Phoenix + PostgreSQL/pgvector + FFmpeg + selective Python, with this pipeline:

1. **Ingest**: web-scraped (yt-dlp, quality-first up to 4K/8K) and user-uploaded videos
2. **Encode**: a single all-I H.264 proxy that serves both review and export (zero re-encoding)
3. **Scene detection** (OpenCV) → **cuts**: cut points define clips *as data* — clips are virtual segments between cuts, with no physical file until export
4. **Human review**: a fast, keyboard-driven LiveView UI for approving/skipping/archiving/merging/splitting clips with frame-accurate navigation — designed for high-throughput expert curation
5. **Export**: stream-copy clip MP4s to S3/CloudFront
6. **Embed**: currently CLIP/DINOv2 image embeddings from keyframes stored in pgvector; a detailed plan exists to move to **frozen V-JEPA 2 video embeddings + a lightweight learned retrieval head trained on human similarity judgments** (anchor + 8–12 candidates, choose top-k), plus a separate structured trick-ontology/metadata layer for faceted and lexical search, and only later a text-alignment head trained on curated language
7. **Query**: a nearest-neighbor exploration UI ("find clips like this") over pgvector

**The core thesis**: motion is the signal for distinguishing tricks (a backside 540 vs frontside 540 is invisible in a single frame); a motion-aware embedding space ("trick2vec") plus expert human curation can produce a searchable, browsable library of the best snowboarding clips ever filmed — something that does not exist today. Discovery of trick clips currently happens through YouTube search, Instagram/TikTok algorithms, and word-of-mouth in forums, all of which are terrible at "show me every backside 540 with a mute grab off a natural feature" or "show me more clips that feel like this one."

**Current state**: the pipeline works end-to-end; curation and embedding exist; there is no public product, no landing page, no users, no monetization, and no explicit written product/GTM strategy. The product shape is deliberately undecided — that is what this research should inform.

## Your Task

Produce a comprehensive research report to guide Heaters' development on two fronts: **(a) technical strategy** for the retrieval/embedding stack, and **(b) product, marketing, and go-to-market strategy** for turning this into something people use. Analyze **all available signal types**: companies, existing and dead apps, app-store reviews, people and creators, videos and their comment sections, discussion forums, academic papers, open-source code, patents/legal precedents, and market data. Cite every claim; favor primary sources; state your confidence and note where evidence is thin.

## Workstream A — Market & Competitive Landscape

1. **Direct and adjacent products**: Map every company/app touching (i) action-sports video, (ii) sports-clip search and highlight tooling, (iii) semantic video search. Include at least: Hudl, Veo, Trace/Traace, Pixellot, Carv, Slopes, Snoww, Burton's media properties, Whitelines/Onboard archives, Newschoolers' media stack, The Berrics/Braille (skate parallels), CrowdRiff, and video-AI infra players (Twelve Labs, Moments Lab, Coactive, Vidrovr, Google/Meta video-retrieval offerings). For each: what they do, business model, traction signals, and what they conspicuously *don't* do.
2. **Dead and zombie startups**: Find action-sports video apps and clip-organization startups that failed (e.g., early ski/snowboard edit apps, GoPro's software ambitions, Quik's history, WeVideo-era tools, RideOn, Cape Productions). Diagnose *why* — market too small, distribution failure, content rights, timing?
3. **The footage supply chain**: Who films snowboarding (pro filmers, park crews, resorts, contest orgs like X Games/Dew Tour/Natural Selection, brands, everyday riders)? Where does footage accumulate and rot (hard drives, unlisted YouTube, Instagram)? Who feels pain organizing/finding it?
4. **Market sizing with honesty**: Snowboarding participation and content-consumption numbers, and the realistic size of adjacent expansions (ski, skate, surf, MTB, BMX, climbing). Is this a venture-scale market, a lifestyle business, or a wedge into broader sports-video retrieval?

## Workstream B — Audience, Community & Demand Signals

1. Mine **Newschoolers forums, Reddit (r/snowboarding, r/snowboardingnoobs, r/skiing, r/NewSkaters), Slush, Discord communities, and YouTube/TikTok/Instagram comment sections** for evidence of the discovery problem: people asking "what trick is this?", "where can I find clips of X?", requests for reference footage when learning tricks, filmers/editors complaining about footage organization.
2. Profile the **creator ecosystem**: trick-tip channels (Snowboard Addiction, Malcolm Moore, Tommie Bennett, etc.), edit compilers, archive accounts (e.g., Instagram accounts reposting classic video parts). What formats go viral? What do their audiences ask for? Which creators would be natural early partners or first power-users of a searchable trick library?
3. Identify **distinct user personas** and rank them by pain intensity and willingness to pay: riders learning tricks, filmers/editors, media orgs, brands/marketing teams, contest judges/organizers, coaches, nostalgic core riders.

## Workstream C — Product Shapes & Viral Features

Evaluate (with evidence from analogous products, not vibes) the promise of each candidate product shape, and propose others you discover:

- **"Shazam for tricks"** — point at a clip, get the trick identified and similar clips
- **Search/browse the canon** — the definitive, searchable archive of great snowboarding clips ("every backside 180 in Vivid Dreams-era parts")
- **Learning tool** — trick progression trees with curated reference clips at each step
- **Daily/weekly curated feed** — "heater of the day", themed drops, era/rider/spot deep-dives
- **Filmer/editor tool** — upload your season's footage, get it auto-cut, trick-tagged, and searchable
- **Games/social** — clip battles, guess-the-trick, fantasy contests, S.K.A.T.E.-style challenges
- **B2B API** — trick recognition / video-similarity embeddings for media orgs, contest broadcasters, brands

For each: closest existing analogue and its outcome, virality mechanics, cold-start problem, content-rights exposure, and fit with the current architecture (expert curation + motion embeddings).

## Workstream D — Go-to-Market & Monetization

1. Study **niche-vertical GTM precedents**: products that won a small passionate community first (Strava's early running/cycling clubs, Letterboxd, Chess.com, Bandcamp, TrainerRoad, OnX). What did the first 1,000 users look like and how were they acquired?
2. Realistic **monetization paths** for each persona: subscriptions, licensing curated collections, brand partnerships, B2B API, white-label for contests/media. What do comparable niche products actually charge and earn?
3. **Marketing channels** ranked by evidence: SEO on trick names (search-volume data for "backside 540 tutorial" etc.), TikTok/IG clip accounts, Reddit/Newschoolers presence, creator partnerships, embeddable clips/widgets.
4. A candid assessment: solo-developer constraints — which strategies are executable by one person, and what sequencing minimizes wasted effort?

## Workstream E — Content Rights & Legal

This may be existential; treat it rigorously.

1. Legal posture of **indexing and clipping scraped footage**: fair-use precedents for search/thumbnail indexing (Perfect 10 v. Google, Authors Guild v. Google), transformative-use doctrine for clips, how sports-highlight aggregators and accounts operate in practice, YouTube/Instagram ToS implications of yt-dlp ingestion, DMCA safe harbor if users upload.
2. Practical models others use: link-out vs re-host, revenue share, licensing deals with rights holders (Brain Farm, Teton Gravity, brands, defunct production companies whose catalogs are in limbo), user-generated-only strategies.
3. Recommend a rights strategy per product shape from Workstream C.

## Workstream F — Technical Strategy

1. **Video-embedding SOTA check**: As of now, is frozen V-JEPA 2 (+ learned retrieval head) still the right backbone choice versus newer releases (successors to V-JEPA 2, InternVideo 2.5+, VideoPrism availability changes, Qwen/Gemini video encoders, anything post-mid-2025)? Compare on motion understanding, open weights, inference cost, and embedding-extraction ergonomics.
2. **Fine-grained action recognition literature**: papers and datasets on distinguishing visually-similar athletic maneuvers — FineGym, FSD-10 (figure skating), diving/gymnastics fine-grained benchmarks, any skate/snow-specific datasets. What worked: pose estimation as auxiliary signal, temporal attention, contrastive vs ranking objectives with tiny expert-label budgets?
3. **Label-efficient retrieval training**: best practices for training retrieval heads from hundreds-to-low-thousands of human judgments — listwise ranking losses, active learning / hard-negative mining strategies, inter-annotator reliability for similarity judgments. What labeling UIs have proven most label-efficient (anchor+candidates vs triplets vs swipe)?
4. **Auto trick recognition**: feasibility of zero/few-shot trick classification on top of the embedding space; anyone who has shipped this (ski/snowboard apps with airtime/rotation detection from IMU — Carv, Slopes, WOO for kite — and vision-based attempts)?
5. **Infra & cost**: GPU options for a solo dev running V-JEPA 2-class backfills and periodic head retraining (Modal, Replicate, RunPod, Fly GPU, Lambda, spot batch) with realistic cost estimates per 10k clips; pgvector scaling limits and when HNSW/pgvectorscale or a dedicated ANN store becomes necessary; scene-detection quality upgrades (TransNetV2 vs PySceneDetect/OpenCV) since cut quality gates everything downstream.
6. **Open-source landscape**: existing repos for video similarity search, sports-clip tooling, and JEPA-style embedding extraction worth reusing or learning from.

## Deliverables

Produce a report with:

1. **Landscape map** — competitors/adjacents organized by axis (consumer↔B2B, archive↔tooling), with the white space Heaters occupies
2. **Opportunity assessment** — top 3 product shapes, ranked, each with: target persona, evidence of demand, virality/growth mechanic, rights exposure, solo-dev feasibility
3. **GTM recommendation** — first-100-users and first-1,000-users plan for the winning shape, with channel priorities
4. **Rights strategy** — the recommended legal posture and its constraints on product design
5. **Technical recommendations** — confirm or revise the V-JEPA 2 + retrieval-head plan with citations; concrete model/infra/cost picks; the 2–3 highest-leverage technical decisions coming up
6. **Risk register** — the ways this dies (legal, market-too-small, cold-start, solo-dev burnout) with mitigations
7. **90-day sequencing suggestion** — what to build/validate first, integrating product and technical tracks

Throughout: distinguish established fact, reasonable inference, and speculation. Where community sentiment is a key input, quote representative primary posts/comments with links. End with the 5 most important open questions this research could not resolve.
