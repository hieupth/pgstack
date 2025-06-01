# PostgreSQL Performance Stack
A production-ready PostgreSQL setup optimized for high-performance applications with connection pooling and caching layer.
```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Applications  │───→│    PgBouncer    │───→│   PostgreSQL    │
│                 │    │ Connection Pool │    │   Databases     │
└─────────────────┘    └─────────────────┘    └─────────────────┘
```
## License
[Apache License 2.0](LICENSE).<br>
Copyright &copy; 2025 [Hieu Pham](https://github.com/hieupth). All rights reserved.