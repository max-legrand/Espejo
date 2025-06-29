 FROM ubuntu:latest

 # Create necessary directories
 RUN mkdir -p /app/zig-out
 RUN mkdir -p /app/static
 RUN mkdir -p /app/upload
 RUN mkdir -p /app/web/dist
 

 # Copy files into the container
 COPY prod/dist/espejo /app/zig-out/bin/espejo
 # COPY prod/dist/wasm.wasm /app/zig-out/bin/wasm.wasm
 # COPY static/ /app/static/
 COPY web/dist/ /app/web/dist/

 # Upload is a mounted volume
 # COPY upload/ /app/upload/

 # Set the working directory
 WORKDIR /app

 # Make the executable executable
 RUN chmod +x zig-out/bin/espejo

 # Expose the port
 EXPOSE 3000

 # Run the executable
 CMD ["./zig-out/bin/espejo"]
