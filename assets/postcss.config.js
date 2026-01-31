module.exports = (ctx) => ({
  plugins: [
    require('postcss-import'),
    require('autoprefixer'),
    // Only minify CSS in production builds
    ctx.env === 'production' ? require('cssnano')({ preset: 'default' }) : false
  ].filter(Boolean)
})