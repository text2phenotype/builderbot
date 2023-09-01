# syntax=docker/dockerfile:experimental
FROM ubuntu:latest

# Run the scripts together so they end up as a single layer.
RUN apt update && apt install -y curl wget

# This command is what launches by default. This should be overwritten by the launching process
CMD ["/bin/bash"]
