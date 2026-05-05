//! By convention, root.zig is the root source file when making a library.

// Re-export the public functions of this library in this file.
// This way, users of this library can just import the root module and have access
// to all the public declarations of the library without having to know about the
// internal file structure of the library.
