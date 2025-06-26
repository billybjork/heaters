# Heaters Pipeline Refactor Plan

## Overview

This refactor plan implements the architectural improvements suggested in the recent code review, focusing on making our Oban-based video processing pipeline more declarative, maintainable, and aligned with Elixir best practices.

## Current State Analysis

Based on the codebase review, we currently have:
- **Dispatcher**: Hand-coded steps with repetitive patterns
- **Workers**: Significant boilerplate duplication across 8+ worker files
- **Task modules**: Good separation but inconsistent return patterns
- **Error handling**: Scattered across workers without centralization

## Goals

1. **Declarative dispatcher** - Data-driven pipeline definition
2. **DRY workers** - Generic worker behavior with minimal per-worker code
3. **Consistent task interfaces** - Structured return types and error handling
4. **Better observability** - Centralized logging and error analytics
5. **Maintainable architecture** - Clear separation of concerns

---

## Phase 1: Dispatcher Refactor (Data-Driven Pipeline)

**Priority**: High  
**Estimated Time**: 2-3 hours  
**Dependencies**: None

### Step 1.1: Create Pipeline Configuration Module

Create `lib/heaters/workers/pipeline_config.ex`:

```elixir
defmodule Heaters.Workers.PipelineConfig do
  @moduledoc """
  Declarative pipeline configuration for the Dispatcher.
  
  Defines the complete workflow as data rather than code.
  """
  
  alias Heaters.Videos.Queries, as: VideoQ
  alias Heaters.Clips.Queries, as: ClipQ
  alias Heaters.Events.EventProcessor
  alias Heaters.Workers.Videos.IngestWorker
  alias Heaters.Workers.Clips.{SpriteWorker, KeyframeWorker, EmbeddingWorker, ArchiveWorker}

  @stages [
    %{
      label: "new videos → ingest",
      query: fn -> VideoQ.get_videos_by_state("new") end,
      build: fn v -> IngestWorker.new(%{source_video_id: v.id}) end
    },
    %{
      label: "spliced clips → sprites", 
      query: fn -> ClipQ.get_clips_by_state("spliced") end,
      build: fn c -> SpriteWorker.new(%{clip_id: c.id}) end
    },
    %{
      label: "review actions",
      call: fn -> EventProcessor.commit_pending_actions() end
    },
    %{
      label: "approved clips → keyframes",
      query: fn -> ClipQ.get_clips_by_state("review_approved") end,
      build: fn c -> KeyframeWorker.new(%{clip_id: c.id, strategy: "multi"}) end
    },
    %{
      label: "keyframed clips → embeddings",
      query: fn -> ClipQ.get_clips_by_state("keyframed") end,
      build: fn c -> 
        EmbeddingWorker.new(%{
          clip_id: c.id, 
          model_name: "clip-vit-base-patch32", 
          generation_strategy: "multi"
        })
      end
    },
    %{
      label: "review_archived clips → archive",
      query: fn -> ClipQ.get_clips_by_state("review_archived") end,
      build: fn c -> ArchiveWorker.new(%{clip_id: c.id}) end
    }
  ]

  def stages, do: @stages
end
```

### Step 1.2: Refactor Dispatcher Implementation

Update `lib/heaters/workers/dispatcher.ex`:

**Key Changes**:
- Replace hand-coded steps with `Enum.each(@stages, &run_stage/1)`
- Extract `run_stage/1` helper functions for query/build and call patterns
- Preserve existing logging patterns
- Add stage execution metrics

### Step 1.3: Test Dispatcher Changes

- Run existing dispatcher tests
- Verify pipeline behavior unchanged
- Add tests for new `run_stage/1` functions

---

## Phase 2: Generic Worker Foundation

**Priority**: High  
**Estimated Time**: 4-5 hours  
**Dependencies**: Phase 1 complete

### Step 2.1: Create Generic Worker Behavior

Create `lib/heaters/workers/generic_worker.ex`:

```elixir
defmodule Heaters.Workers.GenericWorker do
  @moduledoc """
  Generic worker behavior that eliminates boilerplate across all workers.
  
  Provides:
  - Standardized error handling and logging
  - Automatic next-stage job enqueuing
  - Consistent telemetry and observability
  - Centralized retry logic
  """
  
  defmacro __using__(opts) do
    quote do
      use Oban.Worker, unquote(opts)
      @behaviour Heaters.Workers.GenericWorker
      require Logger

      @impl Oban.Worker
      def perform(%Oban.Job{args: args} = job) do
        Logger.info("#{__MODULE__}: Starting job with args: #{inspect(args)}")
        
        start_time = System.monotonic_time()
        
        try do
          with :ok <- handle(args),
               :ok <- enqueue_next(args) do
            duration = System.monotonic_time() - start_time
            Logger.info("#{__MODULE__}: Job completed successfully in #{duration}μs")
            :ok
          else
            {:error, reason} ->
              Logger.error("#{__MODULE__}: Job failed: #{inspect(reason)}")
              {:error, reason}
          end
        rescue
          error ->
            Logger.error("#{__MODULE__}: Job crashed: #{Exception.message(error)}")
            {:error, Exception.message(error)}
        end
      end

      # Callbacks to implement in concrete modules
      @callback handle(map()) :: :ok | {:error, term()}
      @callback enqueue_next(map()) :: :ok | {:error, term()}
      
      # Default implementation for workers that don't enqueue next jobs
      def enqueue_next(_args), do: :ok
      defoverridable enqueue_next: 1
    end
  end
end
```

### Step 2.2: Migrate First Worker (SplitWorker)

Update `lib/heaters/workers/clips/split_worker.ex`:

**Before**: 47 lines of boilerplate  
**After**: ~15 lines of business logic

```elixir
defmodule Heaters.Workers.Clips.SplitWorker do
  use Heaters.Workers.GenericWorker, queue: :media_processing
  
  alias Heaters.Clips.Transform.Split
  alias Heaters.Workers.Clips.SpriteWorker

  @impl Heaters.Workers.GenericWorker
  def handle(%{"clip_id" => clip_id, "split_at_frame" => split_at_frame}) do
    case Split.run_split(clip_id, split_at_frame) do
      {:ok, %{metadata: %{new_clip_ids: new_clip_ids}}} when is_list(new_clip_ids) ->
        :ok
      {:ok, other} ->
        {:error, "Split finished with unexpected payload: #{inspect(other)}"}
      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Heaters.Workers.GenericWorker  
  def enqueue_next(%{"clip_id" => _id} = args) do
    # Extract new_clip_ids from the Split result stored in args by handle/1
    case Map.get(args, "new_clip_ids") do
      ids when is_list(ids) ->
        jobs = Enum.map(ids, &SpriteWorker.new(%{clip_id: &1}))
        {:ok, _} = Oban.insert_all(jobs)
        :ok
      _ ->
        {:error, "No new_clip_ids found to enqueue sprite workers"}
    end
  end
end
```

### Step 2.3: Test Generic Worker

- Create comprehensive tests for `GenericWorker`
- Test error handling, logging, and telemetry
- Verify `SplitWorker` behavior unchanged

---

## Phase 3: Worker Migration

**Priority**: Medium  
**Estimated Time**: 6-8 hours  
**Dependencies**: Phase 2 complete

### Step 3.1: Analyze Worker Patterns

Document current worker patterns:
1. **Simple workers** (no next-stage): `ArchiveWorker`, `SpriteWorker`
2. **Chain workers** (enqueue next): `IngestWorker`, `KeyframeWorker` 
3. **Complex workers** (conditional logic): `EmbeddingWorker`

### Step 3.2: Migrate Workers (Parallel)

**Migration order** (can be done in parallel):

1. **SpriteWorker** - Simple, no next-stage enqueueing
2. **ArchiveWorker** - Simple cleanup logic
3. **KeyframeWorker** - Chain to EmbeddingWorker
4. **EmbeddingWorker** - Final stage, no next-stage
5. **IngestWorker** - Chain to SpliceWorker  
6. **MergeWorker** - Chain to SpriteWorker

**Each migration**:
- Extract business logic to `handle/1`
- Extract job enqueueing to `enqueue_next/1`
- Remove boilerplate error handling and logging
- Test individual worker behavior

### Step 3.3: Update Pipeline Config

Update `PipelineConfig` to reference migrated workers.

---

## Phase 4: Task Module Standardization

**Priority**: Medium  
**Estimated Time**: 3-4 hours  
**Dependencies**: Phase 3 complete

### Step 4.1: Define Result Structs

Create structured return types in each transform module:

```elixir
# In lib/heaters/clips/transform/split.ex
defmodule Heaters.Clips.Transform.Split.Result do
  @enforce_keys [:status, :original_clip_id, :new_clip_ids]
  defstruct [:status, :original_clip_id, :new_clip_ids, :created_clips, :cleanup, :metadata]
end

# Similar for Sprite.Result, Keyframe.Result, etc.
```

### Step 4.2: Update Task Return Types

Update transform modules to return structured results:

```elixir
# Instead of returning maps, return structs
def run_split(clip_id, split_at_frame) do
  # ... existing logic ...
  {:ok, %Split.Result{
    status: "success",
    original_clip_id: clip_id, 
    new_clip_ids: new_clip_ids,
    # ... other fields
  }}
end
```

### Step 4.3: Update Workers for Struct Returns

Update workers to pattern match on structured results:

```elixir
def handle(%{"clip_id" => clip_id, "split_at_frame" => split_at_frame}) do
  case Split.run_split(clip_id, split_at_frame) do
    {:ok, %Split.Result{new_clip_ids: new_clip_ids}} ->
      # Store result for enqueue_next/1
      Process.put(:split_result, new_clip_ids)
      :ok
    {:error, reason} ->
      {:error, reason}
  end
end
```

---

## Phase 5: Advanced Improvements

**Priority**: Low  
**Estimated Time**: 4-6 hours  
**Dependencies**: Phase 4 complete

### Step 5.1: Enhanced Error Analytics

Add to `GenericWorker`:
- Structured error reporting
- Exponential backoff with `retry: :infinite`
- Error categorization (transient vs permanent)

### Step 5.2: Observability Improvements

- Add `tags:` to all `use Oban.Worker` declarations
- Implement telemetry events in `GenericWorker`
- Add performance metrics collection

### Step 5.3: Testing Improvements

- Use `Oban.Testing` for synchronous test execution
- Create test helpers for worker testing
- Add integration tests for full pipeline

### Step 5.4: Transaction Safety

Implement `Ecto.Multi` for atomic DB updates + job enqueuing:

```elixir
defp atomic_update_and_enqueue(clip, update_attrs, jobs) do
  Multi.new()
  |> Multi.update(:clip, ClipQueries.change_clip(clip, update_attrs))
  |> Multi.run(:jobs, fn _repo, _changes ->
    {:ok, Oban.insert_all(jobs)}
  end)
  |> Repo.transaction()
end
```

---

## Implementation Strategy

### Execution Order
1. **Phase 1** (Dispatcher) - Immediate value, low risk
2. **Phase 2** (Generic Worker) - Foundation for rest
3. **Phase 3** (Worker Migration) - Can be done incrementally
4. **Phase 4** (Task Standardization) - Polish and consistency
5. **Phase 5** (Advanced Features) - Optional improvements

### Risk Mitigation
- **Incremental deployment** - Deploy and test each phase separately
- **Feature flags** - Use config switches to toggle between old/new implementations
- **Monitoring** - Watch error rates and job completion times
- **Rollback plan** - Keep old implementations available during transition

### Testing Strategy
- **Unit tests** for each component
- **Integration tests** for worker chains
- **Load testing** with representative workloads
- **Backward compatibility** tests

### Success Metrics
- **Reduced code duplication** - Measure lines of code in workers
- **Improved error rates** - Monitor job failure patterns
- **Better observability** - Structured logging and metrics
- **Easier maintenance** - Time to add new worker types

---

## Decision Points

### Choice 1: Pipeline Configuration Location
**Option A**: Keep `@stages` in `Dispatcher`  
**Option B**: Separate `PipelineConfig` module  
**Option C**: External config file  

**Recommendation**: Option B - Separate module for better testability and reusability.

### Choice 2: Error Handling Strategy
**Option A**: Fail fast - let Oban retry  
**Option B**: Graceful degradation with fallbacks  
**Option C**: Circuit breaker patterns  

**Recommendation**: Option A initially, evolve to Option C for critical paths.

### Choice 3: Worker Migration Strategy
**Option A**: Big bang - migrate all at once  
**Option B**: Incremental - one worker at a time  
**Option C**: Parallel - migrate compatible workers together  

**Recommendation**: Option C with careful dependency management.

---

## Resources Needed

### Development Time
- **Phase 1**: 2-3 hours
- **Phase 2**: 4-5 hours  
- **Phase 3**: 6-8 hours
- **Phase 4**: 3-4 hours
- **Phase 5**: 4-6 hours
- **Total**: 19-26 hours

### Testing Time
- **Unit tests**: 6-8 hours
- **Integration tests**: 4-6 hours
- **Manual testing**: 2-3 hours
- **Total**: 12-17 hours

### Documentation
- **Code documentation**: 2-3 hours
- **Migration guides**: 1-2 hours
- **Architecture docs**: 1-2 hours
- **Total**: 4-7 hours

**Grand Total**: 35-50 hours

---

## Next Steps

1. **Review this plan** with the team
2. **Choose decision points** based on project priorities
3. **Set up feature branch** for refactor work
4. **Begin Phase 1** with dispatcher refactor
5. **Establish testing pipeline** for continuous validation

This refactor will significantly improve the maintainability and robustness of the video processing pipeline while preserving all existing functionality. 