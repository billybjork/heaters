# Heaters Web Frontend Design Principles

## Overview

This document outlines the core design principles for the Heaters web frontend, built on Phoenix LiveView with a focus on simplicity, performance, and maintainability. Our approach prioritizes native web capabilities over complex JavaScript frameworks.

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

### 2. Modern CSS Over Complex JavaScript

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

### 3. Progressive Enhancement

**Principle**: Build core functionality that works without JavaScript, then enhance with LiveView and modern CSS.

**Why**: Ensures the application works for all users regardless of JavaScript availability or network conditions.

**Implementation**:
- Core navigation and content display work with standard HTML forms
- LiveView provides real-time updates and enhanced interactivity
- CSS provides visual polish and responsive design
- Graceful degradation when JavaScript is disabled

### 4. Semantic HTML

**Principle**: Use meaningful HTML elements that convey structure and purpose.

**Why**: Improves accessibility, SEO, and maintainability while providing better default behaviors.

**Implementation**:
- Use `<nav>`, `<main>`, `<section>`, `<article>` for structure
- Leverage `<button>`, `<form>`, `<input>` for interactions
- Utilize ARIA attributes when needed for complex interactions
- Ensure proper heading hierarchy (`<h1>` through `<h6>`)

### 5. Performance-First

**Principle**: Optimize for Core Web Vitals and user-perceived performance.

**Why**: Fast loading and responsive interactions improve user experience and SEO.

**Implementation**:
- Minimize JavaScript bundle size
- Use CSS for animations and transitions
- Leverage LiveView's efficient diffing and patching
- Implement proper caching strategies
- Optimize images and media assets

## Architecture Alignment

These frontend principles align with the backend's functional architecture:

- **URL-First Design** complements the backend's declarative pipeline configuration
- **Modern CSS** supports the clip player approach for instant playback
- **Progressive Enhancement** works with the system's resumable processing capabilities
- **Performance-First** aligns with the backend's 78% S3 operation reduction and FLAME environment optimizations

## Development Guidelines

1. **Start with HTML**: Build the core functionality with semantic HTML
2. **Add LiveView**: Enhance with real-time updates and interactivity
3. **Polish with CSS**: Use modern CSS for animations and responsive design
4. **Test Performance**: Ensure fast loading and smooth interactions
5. **Validate Accessibility**: Test with screen readers and keyboard navigation

## Future Considerations

As the frontend evolves, we'll maintain these principles while exploring:
- View Transitions API for page transitions
- Speculation Rules for instant navigation
- Modern CSS features for enhanced interactivity
- LiveView's evolving capabilities for real-time features

---

*This document will be expanded as the frontend architecture evolves and new patterns emerge.* 