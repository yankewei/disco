# Repository Guidelines

## Project Overview

Disco is a macOS desktop coding-agent client written in Rust. It presents several model sources (Codex, OpenCode Go, DeepSeek, Kimi) through one conversation experience while preserving the **execution semantics of each source** — a Codex turn is executed by the local Codex app-server; a remote provider turn is executed by Disco's own runtime.

## Project Principle
1. 尽最大努力保持 macOS 原生体验和 UI (maximize macOS-native experience and UI).
2. 尽量复用 rust 的 crate，而不是重新写一个 crate，例如 ACP 已有 rust-sdk
