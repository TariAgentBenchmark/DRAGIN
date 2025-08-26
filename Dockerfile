# Use CUDA-enabled Python 3.9 image as base
FROM nvidia/cuda:11.8-devel-ubuntu20.04

# Install Python 3.9
RUN apt-get update && apt-get install -y \
    software-properties-common \
    && add-apt-repository ppa:deadsnakes/ppa \
    && apt-get update \
    && apt-get install -y \
    python3.9 \
    python3.9-dev \
    python3.9-distutils \
    python3-pip \
    && update-alternatives --install /usr/bin/python python /usr/bin/python3.9 1 \
    && update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.9 1 \
    && rm -rf /var/lib/apt/lists/*

# Set environment variables
ENV PYTHONUNBUFFERED=1
ENV DEBIAN_FRONTEND=noninteractive

# Set working directory
WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y \
    wget \
    curl \
    unzip \
    gzip \
    tar \
    git \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Install additional tools for data processing
RUN apt-get update && apt-get install -y \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements first for better Docker layer caching
COPY requirements.txt .

# Install CUDA-compatible PyTorch first (as specified in README)
RUN pip install --no-cache-dir torch==2.1.1+cu118 torchvision==0.16.1+cu118 torchaudio==2.1.1+cu118 --index-url https://download.pytorch.org/whl/cu118

# Install Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Download and install spaCy English model
RUN python -m spacy download en_core_web_sm

# Create directories for data and results
RUN mkdir -p /app/data/dpr \
    && mkdir -p /app/result \
    && mkdir -p /app/sgpt/encode_result

# Copy the application code
COPY . .

# Create a script to wait for external Elasticsearch service
RUN echo '#!/bin/bash\n\
set -e\n\
\n\
# Wait for external Elasticsearch service to be ready\n\
ELASTICSEARCH_URL="${ELASTICSEARCH_HOST:-elasticsearch}:${ELASTICSEARCH_PORT:-9200}"\n\
echo "Waiting for Elasticsearch at $ELASTICSEARCH_URL..."\n\
\n\
until curl -s "http://$ELASTICSEARCH_URL" > /dev/null; do\n\
    echo "Elasticsearch not ready yet, waiting..."\n\
    sleep 5\n\
done\n\
\n\
echo "Elasticsearch is ready at $ELASTICSEARCH_URL!"\n\
' > /app/wait_for_elasticsearch.sh && chmod +x /app/wait_for_elasticsearch.sh

# Create a script to download Wikipedia data
RUN echo '#!/bin/bash\n\
set -e\n\
\n\
# Download Wikipedia dump if not already present\n\
if [ ! -f "/app/data/dpr/psgs_w100.tsv" ]; then\n\
    echo "Downloading Wikipedia dump..."\n\
    mkdir -p /app/data/dpr\n\
    wget -O /app/data/dpr/psgs_w100.tsv.gz https://dl.fbaipublicfiles.com/dpr/wikipedia_split/psgs_w100.tsv.gz\n\
    cd /app/data/dpr\n\
    gzip -d psgs_w100.tsv.gz\n\
    cd /app\n\
    echo "Wikipedia dump downloaded and extracted!"\n\
else\n\
    echo "Wikipedia dump already exists."\n\
fi\n\
' > /app/download_wikipedia.sh && chmod +x /app/download_wikipedia.sh

# Create a script to build the Wikipedia index
RUN echo '#!/bin/bash\n\
set -e\n\
\n\
# Wait for external Elasticsearch service\n\
./wait_for_elasticsearch.sh\n\
\n\
# Download Wikipedia data\n\
./download_wikipedia.sh\n\
\n\
# Build the index\n\
echo "Building Wikipedia index..."\n\
python prep_elastic.py --data_path data/dpr/psgs_w100.tsv --index_name wiki\n\
echo "Wikipedia index built successfully!"\n\
' > /app/setup_index.sh && chmod +x /app/setup_index.sh

# Create a script to download datasets
RUN echo '#!/bin/bash\n\
set -e\n\
\n\
echo "Downloading datasets..."\n\
\n\
# Download StrategyQA\n\
if [ ! -d "/app/data/strategyqa" ]; then\n\
    echo "Downloading StrategyQA..."\n\
    wget -O /app/data/strategyqa_dataset.zip https://storage.googleapis.com/ai2i/strategyqa/data/strategyqa_dataset.zip\n\
    mkdir -p /app/data/strategyqa\n\
    unzip /app/data/strategyqa_dataset.zip -d /app/data/strategyqa\n\
    rm /app/data/strategyqa_dataset.zip\n\
    echo "StrategyQA downloaded!"\n\
fi\n\
\n\
# Download HotpotQA\n\
if [ ! -f "/app/data/hotpotqa/hotpotqa-dev.json" ]; then\n\
    echo "Downloading HotpotQA..."\n\
    mkdir -p /app/data/hotpotqa\n\
    wget -O /app/data/hotpotqa/hotpotqa-dev.json http://curtis.ml.cmu.edu/datasets/hotpot/hotpot_dev_distractor_v1.json\n\
    echo "HotpotQA downloaded!"\n\
fi\n\
\n\
# Note: 2WikiMultihopQA requires manual download from Dropbox\n\
# IIRC is already present in the data directory\n\
\n\
echo "Dataset download completed!"\n\
echo "Note: For 2WikiMultihopQA, please manually download from:"\n\
echo "https://www.dropbox.com/s/ms2m13252h6xubs/data_ids_april7.zip?e=1"\n\
echo "and extract to /app/data/2wikimultihopqa"\n\
' > /app/download_datasets.sh && chmod +x /app/download_datasets.sh

# No need to expose Elasticsearch port since it's handled by docker-compose

# Set the default command
CMD ["/bin/bash"]
