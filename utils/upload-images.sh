#!/bin/bash

GCS_BUCKET=${1:-"brev-image-prestage"}

# Configure parallel downloads
# Use more threads for faster downloads
PARALLEL_THREADS=16
# Use more processes for parallel downloads
PARALLEL_PROCESSES=8
# Set higher sliced download threshold for large files (50MB)
SLICED_OBJECT_THRESHOLD=50M

# Make sure GCS_BUCKET is set in your environment
if [ -z "$GCS_BUCKET" ]; then
  echo "GCS_BUCKET variable is not set."
  exit 1
fi

# Define the list of images
# images=(
#   "nvcr.io/nvidia/rapidsai/notebooks:24.12-cuda12.5-py3.12"
#   "nvcr.io/nvidia/clara/clara-parabricks:4.4.0-1"
#   "nvcr.io/nvidia/nemo:24.12"
#   "egalinkin/demo"
# )

images=(
  "nvcr.io/nvidia/nemo:24.12"
  "egalinkin/demo"
)

docker logout nvcr.io

# Pull each Docker image
for image in "${images[@]}"; do
  echo "Pulling image: $image"
  docker pull "$image"
done

# Save each image to a tarball. We replace '/' and ':' with '__' to generate a filesystem-safe filename.
for image in "${images[@]}"; do
  safe_name=$(echo "$image" | tr '/:' '__')
  tar_file="${safe_name}.tar"
  echo "Saving image $image to ${tar_file}"
  docker save "$image" -o "$tar_file"
done

# Create a destination folder path within the bucket
destination="gs://${GCS_BUCKET}/"

# Upload tar files in parallel using gsutil's -m flag for multi-threading.
# You can also tweak additional parallel settings if needed.
echo "Uploading tar files to ${destination}"
gsutil -o "GSUtil:parallel_thread_count=$PARALLEL_THREADS" \
    -o "GSUtil:parallel_process_count=$PARALLEL_PROCESSES" \
    -o "GSUtil:sliced_object_download_threshold=$SLICED_OBJECT_THRESHOLD" \
    -m cp *.tar "${destination}"