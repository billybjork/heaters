# Heaters Web Frontend Design Principles

## Overview

This document outlines the core design principles for the Heaters web frontend, built on Phoenix LiveView 1.1 with a focus on simplicity, performance, and maintainability. Our approach prioritizes native web capabilities over complex JavaScript frameworks, leveraging colocated hooks for single-file component architecture.

## Core Principles

### 1. URL-First Design

**Principle**: Use query parameters and URL state as the primary mechanism for application state management.

**Why**: URLs are the web's native state management system. They provide:
- **Bookmarkability**: Users can bookmark and share specific application states
- **Browser Navigation**: Back/forward buttons work naturally
- **SEO Benefits**: Search engines can index different application states
- **Accessibility**: Screen readers and assistive technologies understand URL-based navigation
- **Progressive Enhancement**: Works without JavaScript

**Implementation**:
- Use Phoenix LiveView's `push_patch/2` and `push_navigate/2` for state changes
- Store filters, pagination, and view preferences in query parameters
- Leverage LiveView's built-in URL synchronization

**Example**:
```elixir
# Instead of client-side state management
def handle_event("filter", %{"category" => category}, socket) do
  # Update URL with filter
  {:noreply, push_patch(socket, to: ~p"/clips?category=#{category}")}
end
```

### 5. Colocated Hooks for Single-File Components

**Principle**: Use Phoenix LiveView 1.1's colocated hooks feature for business-specific components to maintain single-file architecture.

**Why**: Colocated hooks provide:
- **Single Source of Truth**: All component logic (Elixir, HTML, JavaScript) in one file
- **Automatic Namespacing**: Hook names are prefixed with module name to prevent collisions
- **Better Maintainability**: Related code stays together for easier debugging and updates
- **Reduced Complexity**: No need to manage separate JavaScript files and imports
- **Type Safety**: Component-specific JavaScript embedded within typed Elixir modules

**When to Use**:
- **Business-specific components**: Like `ClipPlayer` or `ReviewHotkeys` that are unique to your application
- **Complex interactions**: Components requiring custom JavaScript behavior and LiveView integration
- **Tightly coupled logic**: When JavaScript and Elixir logic are interdependent

**When NOT to Use**:
- **Reusable utilities**: Generic hooks like `HoverPlay` that work across multiple components
- **Simple interactions**: Basic hover effects better handled with pure CSS
- **Third-party integrations**: External JavaScript libraries that need broader access

**Implementation**:
```elixir
defmodule HeatersWeb.ClipPlayer do
  use HeatersWeb, :live_component
  alias Phoenix.LiveView.ColocatedHook
  
  def render(assigns) do
    ~H"""
    <div phx-hook=".ClipPlayer" id={@id}>
      <!-- Component HTML -->
    </div>
    <.colocated_script />
    """
  end
  
  def colocated_script(assigns) do
    ~H"""
    <script :type={ColocatedHook} name=".ClipPlayer">
      export default {
        mounted() { /* Component-specific JavaScript */ }
      }
    </script>
    """
  end
end
```

### 6. Modern CSS Over Complex JavaScript

**Principle**: Leverage modern CSS capabilities instead of JavaScript for animations, transitions, and interactive behaviors.

**Why**: Modern CSS provides:
- **Better Performance**: Hardware-accelerated animations and transitions
- **Reduced Bundle Size**: Less JavaScript means faster page loads
- **Browser Optimization**: Browsers can optimize CSS better than JavaScript
- **Accessibility**: CSS transitions work with reduced motion preferences
- **Maintainability**: Declarative CSS is easier to understand and modify

**Implementation**:
- Use CSS Grid and Flexbox for layouts instead of JavaScript positioning
- Leverage CSS transitions and animations for smooth interactions
- Utilize CSS custom properties for theming and dynamic styling

**Example**:
```css
/* Instead of JavaScript-based animations */
.clip-card {
  transition: transform 0.2s ease, box-shadow 0.2s ease;
}

.clip-card:hover {
  transform: translateY(-2px);
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.15);
}
```

### 7. Progressive Enhancement

**Principle**: Build core functionality that works without JavaScript, then enhance with LiveView and modern CSS.

**Why**: Ensures the application works for all users regardless of JavaScript availability or network conditions.

**Implementation**:
- Core navigation and content display work with standard HTML forms
- LiveView provides real-time updates and enhanced interactivity
- CSS provides visual polish and responsive design
- Graceful degradation when JavaScript is disabled

### 8. Semantic HTML

**Principle**: Use meaningful HTML elements that convey structure and purpose.

**Why**: Improves accessibility, SEO, and maintainability while providing better default behaviors.

**Implementation**:
- Use `<nav>`, `<main>`, `<section>`, `<article>` for structure
- Leverage `<button>`, `<form>`, `<input>` for interactions
- Utilize ARIA attributes when needed for complex interactions
- Ensure proper heading hierarchy (`<h1>` through `<h6>`)

### 5. Single-File Components (LiveView 1.1 Colocated Hooks)

**Principle**: Co-locate JavaScript functionality directly within Phoenix components using LiveView 1.1 colocated hooks.

**Why**: Single-file components provide:
- **Better Maintainability**: All related code (Elixir, HEEx, JavaScript) in one file
- **Automatic Namespacing**: Hook names are automatically prefixed to prevent collisions
- **Reduced Complexity**: Eliminates need to manage separate JavaScript files
- **Improved Developer Experience**: Edit logic and template together
- **Type Safety**: JavaScript is compiled and validated at build time

**Implementation**:
```elixir
def my_component(assigns) do
  ~H"""
  <div phx-hook=".MyComponent">
    <!-- Component template -->
  </div>

  <script :type={ColocatedHook} name=".MyComponent">
    export default {
      mounted() {
        // Component JavaScript logic
      },
      updated() {
        // Handle updates
      }
    }
  </script>
  """
end
```

**Benefits Over Separate Files**:
- No need to import/export JavaScript modules
- Automatic compilation and extraction to `phoenix-colocated/` directory
- Built-in module namespacing prevents naming conflicts
- Single source of truth for component behavior

### 6. Performance-First

**Principle**: Optimize for Core Web Vitals and user-perceived performance.

**Why**: Fast loading and responsive interactions improve user experience and SEO.

**Implementation**:
- Minimize JavaScript bundle size with colocated hooks
- Use CSS for animations and transitions
- Leverage LiveView's efficient diffing and patching with `:key` attributes
- Implement proper caching strategies
- Optimize images and media assets

## Architecture Alignment

These frontend principles align with the backend's functional architecture:

- **URL-First Design** complements the backend's declarative pipeline configuration
- **Modern CSS** supports the clip player approach for instant playback
- **Progressive Enhancement** works with the system's resumable processing capabilities
- **Single-File Components** mirror the backend's modular design with everything related in one place
- **Performance-First** aligns with the backend's 78% S3 operation reduction and FLAME environment optimizations
- **Colocated Hooks** reduce complexity similar to how the backend centralizes S3 path management

## Development Guidelines

1. **Start with HTML**: Build the core functionality with semantic HTML
2. **Add LiveView**: Enhance with real-time updates and interactivity  
3. **Add Colocated Hooks**: Use single-file components for JavaScript functionality
4. **Use `:key` Attributes**: Add keys to comprehensions for optimal change tracking
5. **Polish with CSS**: Use modern CSS for animations and responsive design
6. **Test Performance**: Ensure fast loading and smooth interactions
7. **Validate Accessibility**: Test with screen readers and keyboard navigation

## Future Considerations

As the frontend evolves, we'll maintain these principles while exploring:
- **Additional Colocated Hooks**: Convert remaining separate JavaScript files (HoverPlay, etc.)
- **TypeScript Integration**: Add JSDoc annotations for better developer experience
- **Portal Components**: Leverage LiveView 1.1's `<.portal>` for modals and tooltips
- **JS.ignore_attributes**: Use for native HTML elements like `<dialog>` and `<details>`
- **View Transitions API**: For smooth page transitions
- **Speculation Rules**: For instant navigation
- **Modern CSS Features**: Enhanced interactivity patterns

---

*This document will be expanded as the frontend architecture evolves and new patterns emerge.* 