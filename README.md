# go-to-production: A Cloud-Native Journey

> **Note:** This is a "toy" application. The code itself (a simple To-Do list) is intentionally basic. The real value of this repository is the **infrastructure, security, and observability** wrapper around it. It demonstrates how to take a simple app and make it production-ready on Google Cloud.

## Purpose

This repository serves as a reference implementation for modern cloud-native practices on Google Cloud Platform (GCP). It evolves from a simple local Docker setup to a highly available, secure, and observable system running on GKE.

**Key Concepts Demonstrated:**
*   **Infrastructure as Code**: Terraform for GKE, Cloud SQL, and IAM.
*   **CI/CD**: GitHub Actions + Google Cloud Deploy for automated canary releases.
*   **Security**: Workload Identity, Secret Manager, Cloud Armor WAF, and IAM Auth.
*   **Observability**: Prometheus metrics, Cloud Trace, and SLO monitoring.
*   **Resilience**: Circuit breakers, retries, and regional high availability.

## Navigating the Journey

This repository uses **Git Tags** to mark specific points in the productionization journey. You can check out any tag to see the code exactly as it was at that stage.

**How to use tags:**

1.  **List all tags:**
    ```bash
    git tag -l
    ```
2.  **Checkout a specific milestone:**
    ```bash
    git checkout tags/milestone-base-infra
    ```
3.  **Return to the latest version:**
    ```bash
    git checkout main
    ```

👉 **[Read the Full Production Guide](PRODUCTION_JOURNEY.md)** for a detailed walkthrough of each milestone.

---

## Baseline Application (Local Development)

If you want to run the simple, local version of the app (without any cloud dependencies), you **must** check out the `baseline` tag. The `main` branch contains cloud-specific code (Secret Manager, etc.) that will not run locally without GCP credentials.

### 1. Checkout the Baseline
```bash
git checkout tags/baseline
```

### 2. Create a `.env` file
Create a file named `.env` in the root directory:
```
POSTGRES_USER=user
POSTGRES_PASSWORD=password
POSTGRES_DB=todoapp_db
DATABASE_URL=postgres://user:password@db:5432/todoapp_db?sslmode=disable
```

### 3. Build and Run with Docker Compose
```bash
docker-compose up --build
```
The app will be available at [http://localhost:8080](http://localhost:8080).

This command will:
*   Build the Go application Docker image.
*   Start a PostgreSQL database container.
*   Initialize the database with the `init.sql` script, creating the `todos` table.
*   Start the Go application, connecting it to the PostgreSQL database.

### 4. Access the Application

Once the services are up and running, you can access the application in your web browser at:

[http://localhost:8080](http://localhost:8080)

## API Endpoints

The application exposes the following API endpoints:

*   **`GET /todos`**: Retrieve all to-do items.
*   **`POST /todos`**: Add a new to-do item.
    *   Request Body: `{"task": "New task description"}`
*   **`PUT /todos/{id}`**: Update a to-do item (e.g., mark as completed).
    *   Request Body: `{"completed": true}`
*   **`DELETE /todos/{id}`**: Delete a to-do item.

## Technologies Used

*   **Backend**: Go
*   **Database**: PostgreSQL (Cloud SQL with HA + Read Replica)
*   **Containerization**: Docker, Docker Compose
*   **Frontend**: HTML, CSS, JavaScript (served statically)
*   **Cloud**: Google Cloud Platform (GKE, Cloud SQL, Artifact Registry, Cloud Deploy)
*   **Authentication**: Workload Identity, Cloud SQL IAM Authentication
*   **Resilience**: cenkalti/backoff, sony/gobreaker
*   **Observability**: Prometheus, Cloud Monitoring

## Documentation

- **[Milestone 1: Risk Analysis](docs/01_RISK_ANALYSIS.md)**
- **[Milestone 2: Base Infrastructure](docs/02_BASE_INFRASTRUCTURE.md)**
- **[Milestone 3: HA & Scalability](docs/03_HA_SCALABILITY.md)**
- **[Milestone 4: IAM Auth & Secrets](docs/04_IAM_AUTH_AND_SECRETS.md)**
- **[Milestone 5: Security Hardening](docs/05_SECURITY_HARDENING.md)**
- **[Milestone 6: Advanced Deployment](docs/06_ADVANCED_DEPLOYMENT.md)**
- **[Milestone 7: Observability & Metrics](docs/07_OBSERVABILITY_METRICS.md)**
- **[Milestone 8: Resilience & SLOs](docs/08_RESILIENCE_SLOS.md)**
- **[Milestone 9: Tracing & Polish](docs/09_TRACING_AND_POLISH.md)**
- **[Production Journey](PRODUCTION_JOURNEY.md)** - Overview of all milestones
- **[Runbook](docs/RUNBOOK.md)** - Operational procedures

## Pushing to Google Artifact Registry

To push your application's Docker image to Google Artifact Registry, follow these steps:

### 1. Prerequisites

*   **Google Cloud SDK (`gcloud`):** Make sure you have the `gcloud` CLI installed and authenticated. If not, you can install it from the [Google Cloud SDK documentation](https://cloud.google.com/sdk/docs/install) and authenticate by running:
    ```bash
    gcloud auth login
    gcloud config set project [YOUR_PROJECT_ID]
    ```
    Replace `[YOUR_PROJECT_ID]` with your Google Cloud project ID.

*   **Docker:** Ensure you have Docker installed and running on your machine.

### 2. Enable the Artifact Registry API

You need to enable the Artifact Registry API for your project. You can do this with the following command:

```bash
gcloud services enable artifactregistry.googleapis.com
```

### 3. Create an Artifact Registry Repository

Create a Docker repository in Artifact Registry to store your image. Choose a region and a name for your repository.

```bash
gcloud artifacts repositories create [YOUR_REPOSITORY_NAME] \
    --repository-format=docker \
    --location=[YOUR_REGION] \
    --description="Docker repository for my Go app"
```

Replace `[YOUR_REPOSITORY_NAME]` and `[YOUR_REGION]` (e.g., `us-central1`).

### 4. Authenticate Docker

Configure Docker to use your Google Cloud credentials to authenticate with Artifact Registry:

```bash
gcloud auth configure-docker [YOUR_REGION]-docker.pkg.dev
```

Replace `[YOUR_REGION]` with the same region you used in the previous step.

### 5. Build and Tag Your Docker Image

Now, build your Docker image using the `Dockerfile` in your project. Then, tag it with the Artifact Registry path.

```bash
# Define your image name and tag
export IMAGE_NAME="[YOUR_REGION]-docker.pkg.dev/[YOUR_PROJECT_ID]/[YOUR_REPOSITORY_NAME]/todo-app-go:latest"

# Build the image
docker build -t ${IMAGE_NAME} .
```

**Note for cross-architecture builds (e.g., building on ARM for AMD64 deployment):**

If you are building on a machine with a different architecture than your deployment target (e.g., an Apple Silicon Mac for a Linux/AMD64 cloud environment), you should explicitly specify the target platform during the build:

```bash
docker build --platform linux/amd64 -t ${IMAGE_NAME} .
```

This ensures the generated image is compatible with your deployment environment, preventing "exec format error" issues.

Make sure to replace `[YOUR_REGION]`, `[YOUR_PROJECT_ID]`, and `[YOUR_REPOSITORY_NAME]` with your actual values.

### 6. Push the Image to Artifact Registry

Finally, push the tagged image to your Artifact Registry repository:

```bash
docker push ${IMAGE_NAME}
```

## Deploying to Google Cloud Run

After pushing your image to Artifact Registry, you can deploy it to Cloud Run.

### 1. Set up a Cloud SQL for PostgreSQL Instance

Your application needs a PostgreSQL database. You can create a Cloud SQL for PostgreSQL instance by following the [Cloud SQL documentation](https://cloud.google.com/sql/docs/postgres/create-instance), or you can use the following `gcloud` command to create a small, inexpensive instance suitable for development and testing:

```bash
gcloud sql instances create [YOUR_INSTANCE_NAME] \
    --database-version=POSTGRES_14 \
    --tier=db-f1-micro \
    --region=[YOUR_REGION] \
    --storage-type=HDD \
    --storage-size=10GB
```

Replace `[YOUR_INSTANCE_NAME]` and `[YOUR_REGION]` with your desired instance name and Google Cloud region. This command provisions the smallest, most cost-effective instance type.

When you create the instance, note the **Connection name**. You will need it later.

### 2. Create a Database and User

After the instance is created, you need to create the database and a user for your application.

**Create the database:**
```bash
gcloud sql databases create todoapp_db --instance=[YOUR_INSTANCE_NAME]
```

**Create the user:**
```bash
gcloud sql users create user --instance=[YOUR_INSTANCE_NAME] --password=[YOUR_DB_PASSWORD]
```

Replace `[YOUR_INSTANCE_NAME]` and `[YOUR_DB_PASSWORD]` with your actual instance name and a secure password.


### 3. Initialize the Database Schema

Unlike the local Docker setup, Cloud SQL does not automatically run the `init.sql` script. You must manually create the table schema.
201: 
202: **Note:** The CI/CD pipeline now includes an automated job to initialize the database schema using `k8s/db-init-job.yaml`. If you are deploying via the pipeline, this step is handled for you.
203: 
204: If you need to manually initialize it:

1.  **Connect to your instance using the `gcloud` CLI:**
    ```bash
    gcloud sql connect [YOUR_INSTANCE_NAME] --user=user
    ```
    Enter the password for the `user` you created in the previous step.

2.  **Connect to your database:**
    Once in the `psql` shell, connect to your database:
    ```sql
    \c todoapp_db
    ```

3.  **Create the `todos` table:**
    Paste and run the following SQL command to create the necessary table:
    ```sql
    CREATE TABLE IF NOT EXISTS todos (
        id SERIAL PRIMARY KEY,
        task TEXT NOT NULL,
        completed BOOLEAN DEFAULT FALSE
    );
    ```

4.  **Exit the `psql` shell:**
    ```sql
    \q
    ```

### 4. Deploy to Cloud Run

Use the `gcloud run deploy` command to deploy your application. This command will create a new Cloud Run service or update an existing one.

When deploying to Cloud Run with a Cloud SQL instance, you must provide the database connection details via the `DATABASE_URL` environment variable. The format for connecting to a Cloud SQL instance from Cloud Run is specific.

```bash
gcloud run deploy todo-app-go \
    --image [YOUR_REGION]-docker.pkg.dev/[YOUR_PROJECT_ID]/[YOUR_REPOSITORY_NAME]/todo-app-go:latest \
    --platform managed \
    --region [YOUR_REGION] \
    --allow-unauthenticated \
    --add-cloudsql-instances [YOUR_CLOUD_SQL_CONNECTION_NAME] \
    --set-env-vars "DATABASE_URL=postgres://[YOUR_DB_USER]:[YOUR_DB_PASSWORD]@/[YOUR_DB_NAME]?host=/cloudsql/[YOUR_CLOUD_SQL_CONNECTION_NAME]"
```

Replace the following placeholders:
*   `[YOUR_REGION]`: The region where you want to deploy your service.
*   `[YOUR_PROJECT_ID]`: Your Google Cloud project ID.
*   `[YOUR_REPOSITORY_NAME]`: The name of your Artifact Registry repository.
*   `[YOUR_CLOUD_SQL_CONNECTION_NAME]`: The **full connection name** of your Cloud SQL instance (e.g., `your-project:your-region:your-instance`).
*   `[YOUR_DB_USER]`: The username for your Cloud SQL database.
*   `[YOUR_DB_PASSWORD]`: The password for your Cloud SQL database user.
*   `[YOUR_DB_NAME]`: The name of your Cloud SQL database.

This command connects your Cloud Run service to your Cloud SQL instance and securely passes the database credentials as an environment variable.

// test
