 FROM ubuntu:latest

 COPY prod/dist/ /app/zig-out
 COPY static/ /app/static/
 # COPY upload/ /app/upload/
 RUN mkdir /app/upload
 COPY web/dist/ /app/web/dist/

 WORKDIR /app
 RUN chmod +x zig-out/bin/scratchpad
 EXPOSE 3000

 CMD ["./zig-out/bin/scratchpad"]
