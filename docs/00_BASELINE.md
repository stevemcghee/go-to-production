# Milestone 0: Baseline Application (Local Development)

This document outlines how to run the simple, local version of the app (without any cloud dependencies).

## 1. Checkout this Milestone

To run the local version of the app, you **must** check out the `baseline` tag. The `main` branch contains cloud-specific code (Secret Manager, etc.) that will not run locally without GCP credentials.

```bash
git checkout tags/baseline
```

## 2. What was Implemented?

This is the starting point of our journey: a "Toy App" designed to be simple to understand but lacking production features.

**Key Features:**
*   **Go Backend**: A simple HTTP server using `net/http`.
*   **PostgreSQL**: Persistent storage for To-Do items.
*   **Docker Compose**: Orchestrates the app and database locally.
*   **Frontend**: Basic HTML/JS served statically.

**Benefits:**
*   **Simplicity**: Easy to run on a laptop with just Docker.
*   **Fast Feedback**: No cloud deployment time; changes are instant.

## 3. Pitfalls & Considerations

*   **No Security**: Database passwords are in plain text in `.env` files.
*   **Single Point of Failure**: If your laptop dies, the app dies. No high availability.
*   **No Observability**: Logs are just printed to stdout. No metrics or tracing.

## 4. Alternatives Considered

*   **SQLite**: Would be even simpler (no separate DB container).
    *   *Why Postgres?* To mimic a real production stack where the DB is a separate service, allowing us to demonstrate Cloud SQL migration later.

## Usage Instructions

### 1. Create a `.env` file
Create a file named `.env` in the root directory:
```
POSTGRES_USER=user
POSTGRES_PASSWORD=password
POSTGRES_DB=todoapp_db
DATABASE_URL=postgres://user:password@db:5432/todoapp_db?sslmode=disable
```

### 2. Build and Run with Docker Compose
```bash
docker-compose up --build
```
The app will be available at [http://localhost:8080](http://localhost:8080).

### 3. API Endpoints

*   **`GET /todos`**: Retrieve all to-do items.
*   **`POST /todos`**: Add a new to-do item.
    *   Request Body: `{"task": "New task description"}`
*   **`PUT /todos/{id}`**: Update a to-do item.
    *   Request Body: `{"completed": true}`
*   **`DELETE /todos/{id}`**: Delete a to-do item.

## Simple Cloud Deployment (Cloud Run)

If you want to deploy this "toy app" to the cloud without the complexity of GKE, you can use **Cloud Run**. This is a "simple" deployment because it involves manual steps and doesn't use the robust infrastructure (Terraform, CI/CD) introduced in later milestones.

### 1. Prerequisites

*   **Google Cloud SDK (`gcloud`)**: Installed and authenticated.
*   **Artifact Registry API**: Enabled (`gcloud services enable artifactregistry.googleapis.com`).

### 2. Build and Push Image

1.  **Create a Repository**:
    ```bash
    gcloud artifacts repositories create todo-repo \
        --repository-format=docker \
        --location=us-central1 \
        --description="Docker repository for my Go app"
    ```

2.  **Configure Docker Auth**:
    ```bash
    gcloud auth configure-docker us-central1-docker.pkg.dev
    ```

3.  **Build and Push**:
    ```bash
    export IMAGE_NAME="us-central1-docker.pkg.dev/[YOUR_PROJECT_ID]/todo-repo/todo-app-go:baseline"
    docker build --platform linux/amd64 -t ${IMAGE_NAME} .
    docker push ${IMAGE_NAME}
    ```

### 3. Set up Cloud SQL

1.  **Create Instance**:
    ```bash
    gcloud sql instances create todo-db-instance \
        --database-version=POSTGRES_14 \
        --tier=db-f1-micro \
        --region=us-central1
    ```

2.  **Create Database & User**:
    ```bash
    gcloud sql databases create todoapp_db --instance=todo-db-instance
    gcloud sql users create user --instance=todo-db-instance --password=securepassword
    ```

3.  **Initialize Schema**:
    Connect to the instance (e.g., via Cloud Shell or `gcloud sql connect`) and run the SQL from `init.sql`.

### 4. Deploy to Cloud Run

Deploy the container, connecting it to Cloud SQL via the built-in proxy.

```bash
gcloud run deploy todo-app-simple \
    --image ${IMAGE_NAME} \
    --platform managed \
    --region us-central1 \
    --allow-unauthenticated \
    --add-cloudsql-instances [YOUR_PROJECT_ID]:us-central1:todo-db-instance \
    --set-env-vars "DATABASE_URL=postgres://user:securepassword@/todoapp_db?host=/cloudsql/[YOUR_PROJECT_ID]:us-central1:todo-db-instance"
```

**Note**: This deployment method puts the database password in an environment variable, which is **not secure** for production. Milestone 4 addresses this with Secret Manager.
