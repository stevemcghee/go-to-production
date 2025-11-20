<!-- Written by Gemini CLI -->
<!-- This file is licensed under the MIT License. See the LICENSE file for details. -->

# Go To-Do Application

A simple To-Do list application built with Go and PostgreSQL. This application allows users to create, view, update, and delete to-do items.

## Features

*   **Create To-Do Items**: Add new tasks to your list.
*   **View To-Do Items**: See all your pending and completed tasks.
*   **Update To-Do Items**: Mark tasks as completed.
*   **Delete To-Do Items**: Remove tasks from your list.
*   **Persistent Storage**: To-Do items are stored in a PostgreSQL database.

## Prerequisites

Before you begin, ensure you have the following installed:

*   [Docker](https://docs.docker.com/get-docker/)
*   [Docker Compose](https://docs.docker.com/compose/install/)

## Getting Started

Follow these steps to get the application up and running on your local machine.

### 1. Clone the Repository

```bash
git clone https://github.com/gemini/todo-app.git
cd todo-app
```

### 2. Create a `.env` file

Create a file named `.env` in the root directory of the project and add the following content. Replace `your_password` with a strong password for your PostgreSQL database.

```
POSTGRES_USER=user
POSTGRES_PASSWORD=your_password
POSTGRES_DB=todoapp_db
```

### 3. Build and Run with Docker Compose

Navigate to the project root directory and run the following command to build the Docker images and start the services:

```bash
docker-compose up --build
```

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
*   **Database**: PostgreSQL
*   **Containerization**: Docker, Docker Compose
*   **Frontend**: HTML, CSS, JavaScript (served statically)

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

// test me
