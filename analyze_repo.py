import subprocess
import os
import json

CATEGORIES = {
    "Application Code": ["*.go", "templates/", "static/"],
    "IaC": ["terraform/", "k8s/", "Dockerfile", "docker-compose.yml", "skaffold.yaml", "clouddeploy.yaml"],
    "Database": ["init.sql", "migrations/"],
    "CI/CD": [".github/"],
    "Documentation": ["*.md", "docs/", "LICENSE"],
    "Scripts": ["scripts/", "*.py"],
    "Config": [".env", "go.mod", "go.sum", ".gitignore"]
}

def get_category(filename):
    for cat, patterns in CATEGORIES.items():
        for pattern in patterns:
            if pattern.endswith("/"):
                if filename.startswith(pattern) or ("/" + pattern) in filename:
                    return cat
            elif pattern.startswith("*"):
                if filename.endswith(pattern[1:]):
                    return cat
            else:
                if filename == pattern or filename.endswith("/" + pattern):
                    return cat
    return "Other"

def run_command(cmd):
    return subprocess.check_output(cmd, shell=True).decode('utf-8').strip()

def analyze_ref(ref):
    print(f"Analyzing {ref}...")
    try:
        files = run_command(f"git ls-tree -r {ref} --name-only").split('\n')
    except subprocess.CalledProcessError:
        print(f"Error: Could not read ref {ref}")
        return {}

    stats = {}
    
    for f in files:
        if not f: continue
        try:
            # Check if file exists in that ref
            content = run_command(f"git show {ref}:'{f}'")
            lines = len(content.split('\n'))
            cat = get_category(f)
            stats[cat] = stats.get(cat, 0) + lines
        except Exception as e:
            # print(f"Error reading {f} in {ref}: {e}")
            pass
            
    return stats

def main():
    # Define milestones in chronological order
    milestones = [
        ("baseline", "Baseline"),
        ("milestone-risk-analysis", "1. Risk"),
        ("milestone-base-infra", "2. Infra"),
        ("milestone-ha-scale", "3. HA/Scale"),
        ("milestone-iam-auth", "4. IAM"),
        ("milestone-security-hardening", "5. Security"),
        ("milestone-advanced-deployment", "6. Deploy"),
        ("milestone-observability-metrics", "7. Obs"),
        ("milestone-resilience-slos", "8. Robustness"),
        ("milestone-tracing-polish", "9. Polish")
    ]
    
    report = {}
    for tag, label in milestones:
        report[tag] = analyze_ref(tag)
        # Store label in report for chart generation
        report[tag]["_label"] = label
    
    # print(json.dumps(report, indent=2))
    
    generate_chart(report, milestones)

def generate_chart(report, milestones):
    try:
        import matplotlib.pyplot as plt
        import numpy as np
        
        refs = [m[0] for m in milestones]
        labels = [m[1] for m in milestones]
        
        # Extract categories (excluding _label)
        categories = set()
        for r in refs:
            for k in report[r].keys():
                if k != "_label":
                    categories.add(k)
        categories = sorted(list(categories))
        
        if not categories:
            print("No data to plot.")
            return

        x = np.arange(len(refs))
        
        fig, ax = plt.subplots(figsize=(14, 8))
        
        # Create stacked bar chart
        bottom = np.zeros(len(refs))
        # Use a nice color map
        colors = plt.cm.Paired(np.linspace(0, 1, len(categories)))
        
        for i, cat in enumerate(categories):
            vals = [report[r].get(cat, 0) for r in refs]
            ax.bar(x, vals, label=cat, bottom=bottom, color=colors[i])
            bottom += vals
            
        ax.set_ylabel('Total Lines of Code', fontsize=12)
        ax.set_title('Codebase Evolution Across Milestones', fontsize=16, fontweight='bold')
        ax.set_xticks(x)
        ax.set_xticklabels(labels, fontsize=10, rotation=45, ha='right')
        ax.legend(loc='upper left', bbox_to_anchor=(1, 1), fontsize=10)
        ax.grid(axis='y', alpha=0.3)
        
        # Add total labels on top of each bar
        for i, ref in enumerate(refs):
            total = sum(v for k, v in report[ref].items() if k != "_label")
            ax.text(i, total + 50, f'{total:,}', ha='center', va='bottom', fontweight='bold', fontsize=9)
        
        plt.tight_layout()
        plt.savefig('docs/repo_evolution.png', dpi=150)
        print("Chart saved to docs/repo_evolution.png")
        
    except ImportError:
        print("matplotlib not found, skipping chart generation")
    except Exception as e:
        print(f"Error generating chart: {e}")

if __name__ == "__main__":
    main()

