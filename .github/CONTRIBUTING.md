# Contributing Overview
The only requirement is to please not submit AI slop. If you can't explain why you made the changes you made, then it doesn't have a place in this codebase.

# Formatting
Please ensure all code is formatted according to zig's builtin formatter. PRs containing code that is not formatted will be sent back for changes until `zig build lint` runs without error. You can format the relevant code with `zig build fmt`.

# Testing
Tests should be written for anything that has considerable weight. This is a subjective measurement. If you believe that something is volatile (changes to a related system will break behavior) then a test should be written. That being said, if a block of code is tested by another test in the codebase, you need not worry about writing a specific test for it. You also need not concern yourself with code that is practically infallible due to compiler intrinsics, dead-simple functions, etc.
