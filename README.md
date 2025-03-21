# Espejo

Espejo is a web application that allows you to have a shared file storage and "clipboard" between devices on your local network.
This web app can also be hosted to allow for access via the open internet.

Espejo uses websockets to live stream updates and keep all clients in sync with one another.


# Running
To run the project you can use docker (or docker compose):
```bash
docker-compose up
```

You can also run the project directly with the binary (either build from source -- see below -- or if you are on Linux you can use the binary located at `prod/dist`)
```
./zig./zig-out/bin/espejo
```

## Build from source
If you'd like to build from source the following is required:
- Zig v0.14
- A javascript package manager (pnpm will be used for example commands)

Then take the following steps:
1. Install the frontend dependencies
```bash
; pushd web
; pnpm install
; popd
```
2. Run the frontend build step
```bash
; pushd web
; pnpm build
; popd
```
3. Build the zig project
```bash
; zig build --release=safe
```

# Authentication
If you are hosting the application so that it is accessible from the internet you can use the following environment variables to enable authentication:
- `USE_AUTH`: Set to `true` to enable authentication.
- `SP_USER`: The username to use for authentication.
- `SP_PASSWORD`: The password to use for authentication.
- `SP_PROD`: This should be set to the URL which you are hosting the application on, so that authentication cookies can be properly applied to the domain.

# Demo
<details>
<summary>Demo video</summary>
https://github.com/user-attachments/assets/806323dc-a75a-4ac2-a473-b6dc644b979c
</details>
