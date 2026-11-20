---
title: NailVirtuoso Virtual Try On
emoji: 💅
colorFrom: pink
colorTo: purple
sdk: docker
pinned: false
app_port: 7860
license: mit
language:
- en
pipeline_tag: image-segmentation
tags:
- nails
- fashion
- virtual-try-on
- unet
---

NailVirtuoso: AI-Powered Virtual Nail Try-On: 
NailVirtuoso is an AI-powered web application that allows users to virtually try on different nail colors. By uploading an image of their hand, a U-Net deep learning model performs precise nail segmentation, and the user can select any color to see it applied in real-time. This project was developed for the TensorForge '25 AI Buildathon.

## Features
AI-Powered Nail Segmentation: Utilizes a U-Net architecture for accurate nail detection.

Virtual Color Try-On: Apply any selected color to the segmented nails on your uploaded photo.

Web-Based Interface: Easy-to-use application accessible from any web browser.

Containerized Deployment: Packaged with Docker for easy and reproducible setup.

## Local Setup Instructions
Follow these steps to set up and run the project on your local machine.

### Prerequisites
Python 3.9 or later

pip for package management

A virtual environment tool (like venv)

### Installation
Clone the repository:

Bash

git clone https://github.com/your-username/nailvirtuoso.git
cd nailvirtuoso
Create and activate a virtual environment:

Bash

# For Windows
python -m venv venv
.\venv\Scripts\activate

# For macOS/Linux
python3 -m venv venv
source venv/bin/activate
Install the required dependencies:

Bash

pip install -r requirements.txt
Download the pre-trained model:
Ensure your trained model file (nail_segmentation_model.pth) is located in the model/ directory.

### Running the Application
Start the Flask server:

Bash

python run.py
Access the application:
Open your web browser and navigate to http://127.0.0.1:5000.

## Docker Deployment
The easiest way to run this project is by using Docker.

### Prerequisites
Docker Desktop installed and running.

### Quickstart with Docker
Build the Docker image:
From the project's root directory, run the following command:

Bash

docker build -t nail-virtuoso .
Run the Docker container:
This command will start the application and make it accessible on port 5001 of your local machine.

Bash

docker run -p 5001:5000 nail-virtuoso
Access the application:
Open your web browser and navigate to http://localhost:5001.

## Project Structure
.
├── model/
│   └── nail_segmentation_model.pth
├── notebooks/
│   └── data_exploration.ipynb
├── scripts/
│   └── Model Train Stage (it contain code bases and some samll amount of data I use to train models)
|   └── Running_Stage (here is the working code bases)
├── Dockerfile
├── README.md
├── requirements.txt
└── run.py
└── Demo Video.mp4