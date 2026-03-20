// Custom Kubernetes Backup Controller skeleton
// Implements a controller-runtime based operator that watches BackupPolicy CRDs
// and triggers Velero backups on schedule with pre/post hooks.
//
// Build:
//   go mod init backup-controller
//   go get sigs.k8s.io/controller-runtime@v0.17.0
//   go get github.com/vmware-tanzu/velero@v1.13.0
//   go build -o backup-controller ./cmd/main.go
//
// Run:
//   ./backup-controller --kubeconfig ~/.kube/config --leader-elect=false

package main

import (
	"context"
	"fmt"
	"os"
	"time"

	velerov1 "github.com/vmware-tanzu/velero/pkg/apis/velero/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
)

// -----------------------------------------------------------------------------
// BackupPolicy CRD types
// -----------------------------------------------------------------------------

// BackupPolicySpec defines the desired state of BackupPolicy
type BackupPolicySpec struct {
	// Schedule is a cron expression (e.g. "0 2 * * *")
	Schedule string `json:"schedule"`

	// Namespaces to include in the backup
	IncludedNamespaces []string `json:"includedNamespaces,omitempty"`

	// TTL is the backup retention duration (e.g. "720h")
	TTL metav1.Duration `json:"ttl,omitempty"`

	// StorageLocation is the Velero BackupStorageLocation name
	StorageLocation string `json:"storageLocation,omitempty"`

	// SnapshotVolumes controls whether to snapshot PVs
	SnapshotVolumes *bool `json:"snapshotVolumes,omitempty"`

	// PreBackupHooks are exec hooks run in pods before backup
	PreBackupHooks []BackupHook `json:"preBackupHooks,omitempty"`

	// PostBackupHooks are exec hooks run in pods after backup
	PostBackupHooks []BackupHook `json:"postBackupHooks,omitempty"`

	// MaxBackupCount is the max number of Velero Backups to retain
	MaxBackupCount int `json:"maxBackupCount,omitempty"`

	// Paused suspends scheduled backups without deleting the policy
	Paused bool `json:"paused,omitempty"`
}

// BackupHook defines a pre/post backup hook
type BackupHook struct {
	// LabelSelector selects pods to run the hook in
	LabelSelector metav1.LabelSelector `json:"labelSelector"`
	// Container is the container name to exec into
	Container string `json:"container"`
	// Command is the exec command
	Command []string `json:"command"`
	// OnError is the action on hook failure: Continue or Fail
	OnError string `json:"onError,omitempty"`
	// Timeout is the max exec duration
	Timeout metav1.Duration `json:"timeout,omitempty"`
}

// BackupPolicyStatus defines the observed state of BackupPolicy
type BackupPolicyStatus struct {
	// LastBackupTime is when the last backup was triggered
	LastBackupTime *metav1.Time `json:"lastBackupTime,omitempty"`
	// LastBackupName is the name of the last created Velero Backup
	LastBackupName string `json:"lastBackupName,omitempty"`
	// LastBackupPhase is the phase of the last Velero Backup
	LastBackupPhase string `json:"lastBackupPhase,omitempty"`
	// NextBackupTime is the scheduled time for the next backup
	NextBackupTime *metav1.Time `json:"nextBackupTime,omitempty"`
	// TotalBackups is the count of all backups created by this policy
	TotalBackups int `json:"totalBackups,omitempty"`
	// Conditions holds status conditions
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// BackupPolicy is the CRD for managing scheduled Velero backups
// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Schedule",type=string,JSONPath=`.spec.schedule`
// +kubebuilder:printcolumn:name="LastBackup",type=string,JSONPath=`.status.lastBackupName`
// +kubebuilder:printcolumn:name="Phase",type=string,JSONPath=`.status.lastBackupPhase`
// +kubebuilder:printcolumn:name="NextBackup",type=date,JSONPath=`.status.nextBackupTime`
type BackupPolicy struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   BackupPolicySpec   `json:"spec,omitempty"`
	Status BackupPolicyStatus `json:"status,omitempty"`
}

// BackupPolicyList contains a list of BackupPolicy
// +kubebuilder:object:root=true
type BackupPolicyList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []BackupPolicy `json:"items"`
}

// GroupVersionResource for BackupPolicy
var BackupPolicyGVR = schema.GroupVersionResource{
	Group:    "backup.example.com",
	Version:  "v1alpha1",
	Resource: "backuppolicies",
}

// -----------------------------------------------------------------------------
// BackupPolicyReconciler
// -----------------------------------------------------------------------------

type BackupPolicyReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

const (
	backupPolicyFinalizer = "backup.example.com/finalizer"
	veleroNamespace       = "velero"
	requeueInterval       = 60 * time.Second
)

// Reconcile is called whenever a BackupPolicy changes or is re-queued.
func (r *BackupPolicyReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx).WithValues("backuppolicy", req.NamespacedName)

	// Fetch the BackupPolicy instance
	policy := &BackupPolicy{}
	if err := r.Get(ctx, req.NamespacedName, policy); err != nil {
		if errors.IsNotFound(err) {
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, fmt.Errorf("get BackupPolicy: %w", err)
	}

	// Handle deletion / finalizer
	if !policy.DeletionTimestamp.IsZero() {
		return r.handleDeletion(ctx, policy)
	}

	// Add finalizer
	if !controllerutil.ContainsFinalizer(policy, backupPolicyFinalizer) {
		controllerutil.AddFinalizer(policy, backupPolicyFinalizer)
		if err := r.Update(ctx, policy); err != nil {
			return ctrl.Result{}, fmt.Errorf("add finalizer: %w", err)
		}
	}

	// Skip if paused
	if policy.Spec.Paused {
		logger.Info("BackupPolicy is paused, skipping")
		return ctrl.Result{RequeueAfter: requeueInterval}, nil
	}

	// Parse cron schedule and determine if backup should run now
	shouldBackup, nextRun, err := r.shouldRunBackup(policy)
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("parse schedule: %w", err)
	}

	if shouldBackup {
		if err := r.triggerBackup(ctx, policy); err != nil {
			logger.Error(err, "Failed to trigger backup")
			r.setCondition(policy, "BackupFailed", metav1.ConditionTrue, "TriggerFailed", err.Error())
			_ = r.Status().Update(ctx, policy)
			return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
		}
		r.setCondition(policy, "BackupFailed", metav1.ConditionFalse, "BackupTriggered", "Backup triggered successfully")
	}

	// Enforce max backup count retention
	if policy.Spec.MaxBackupCount > 0 {
		if err := r.pruneOldBackups(ctx, policy); err != nil {
			logger.Error(err, "Failed to prune old backups")
		}
	}

	// Sync last backup status
	if err := r.syncBackupStatus(ctx, policy); err != nil {
		logger.Error(err, "Failed to sync backup status")
	}

	// Update next run time in status
	policy.Status.NextBackupTime = &metav1.Time{Time: nextRun}
	if err := r.Status().Update(ctx, policy); err != nil {
		return ctrl.Result{}, fmt.Errorf("update status: %w", err)
	}

	requeueAfter := time.Until(nextRun)
	if requeueAfter < 10*time.Second {
		requeueAfter = requeueInterval
	}
	return ctrl.Result{RequeueAfter: requeueAfter}, nil
}

// handleDeletion runs cleanup before the object is garbage collected.
func (r *BackupPolicyReconciler) handleDeletion(ctx context.Context, policy *BackupPolicy) (ctrl.Result, error) {
	logger := log.FromContext(ctx)
	logger.Info("Handling BackupPolicy deletion", "name", policy.Name)

	// Optionally: delete all associated Velero backups
	// (commented out by default — backups may be needed for recovery even after policy deletion)
	// if err := r.deleteAssociatedBackups(ctx, policy); err != nil {
	//     return ctrl.Result{}, err
	// }

	controllerutil.RemoveFinalizer(policy, backupPolicyFinalizer)
	if err := r.Update(ctx, policy); err != nil {
		return ctrl.Result{}, fmt.Errorf("remove finalizer: %w", err)
	}
	return ctrl.Result{}, nil
}

// shouldRunBackup returns true if the schedule dictates a backup should run now.
func (r *BackupPolicyReconciler) shouldRunBackup(policy *BackupPolicy) (bool, time.Time, error) {
	// Simplified: use a real cron library (e.g. github.com/robfig/cron/v3) in production
	// Here we demonstrate the logic pattern:
	lastRun := time.Time{}
	if policy.Status.LastBackupTime != nil {
		lastRun = policy.Status.LastBackupTime.Time
	}

	// Parse cron expression — placeholder using fixed interval for skeleton
	interval := 24 * time.Hour // replace with actual cron parsing
	nextRun := lastRun.Add(interval)
	if lastRun.IsZero() {
		nextRun = time.Now()
	}

	shouldRun := time.Now().After(nextRun) || lastRun.IsZero()
	return shouldRun, nextRun, nil
}

// triggerBackup creates a Velero Backup object derived from the policy spec.
func (r *BackupPolicyReconciler) triggerBackup(ctx context.Context, policy *BackupPolicy) error {
	logger := log.FromContext(ctx)

	backupName := fmt.Sprintf("%s-%s", policy.Name, time.Now().UTC().Format("20060102-150405"))
	logger.Info("Creating Velero Backup", "name", backupName)

	ttl := policy.Spec.TTL
	if ttl.Duration == 0 {
		ttl = metav1.Duration{Duration: 720 * time.Hour} // 30 days default
	}

	storageLocation := policy.Spec.StorageLocation
	if storageLocation == "" {
		storageLocation = "default"
	}

	backup := &velerov1.Backup{
		ObjectMeta: metav1.ObjectMeta{
			Name:      backupName,
			Namespace: veleroNamespace,
			Labels: map[string]string{
				"backup.example.com/policy":    policy.Name,
				"backup.example.com/namespace": policy.Namespace,
			},
		},
		Spec: velerov1.BackupSpec{
			TTL:                    ttl,
			StorageLocation:        storageLocation,
			IncludedNamespaces:     policy.Spec.IncludedNamespaces,
			SnapshotVolumes:        policy.Spec.SnapshotVolumes,
			IncludeClusterResources: boolPtr(false),
			Hooks: velerov1.BackupHooks{
				Resources: r.buildHookSpecs(policy),
			},
		},
	}

	if err := r.Create(ctx, backup); err != nil {
		return fmt.Errorf("create Velero Backup: %w", err)
	}

	// Update status immediately after trigger
	now := metav1.Now()
	policy.Status.LastBackupTime = &now
	policy.Status.LastBackupName = backupName
	policy.Status.TotalBackups++

	return nil
}

// buildHookSpecs converts BackupPolicy hooks to Velero hook specs.
func (r *BackupPolicyReconciler) buildHookSpecs(policy *BackupPolicy) []velerov1.BackupResourceHookSpec {
	var specs []velerov1.BackupResourceHookSpec

	buildHooks := func(hooks []BackupHook, phase string) {
		for _, h := range hooks {
			timeout := h.Timeout.Duration
			if timeout == 0 {
				timeout = 30 * time.Second
			}
			onError := velerov1.HookErrorModeContinue
			if h.OnError == "Fail" {
				onError = velerov1.HookErrorModeFail
			}

			var execHooks []velerov1.ExecHook
			execHook := velerov1.ExecHook{
				Container: h.Container,
				Command:   h.Command,
				OnError:   onError,
				Timeout:   metav1.Duration{Duration: timeout},
			}

			var preHooks, postHooks []velerov1.ExecHook
			if phase == "pre" {
				preHooks = append(execHooks, execHook)
			} else {
				postHooks = append(execHooks, execHook)
			}
			_ = preHooks
			_ = postHooks

			specs = append(specs, velerov1.BackupResourceHookSpec{
				Name: fmt.Sprintf("%s-hook-%s", phase, h.Container),
				LabelSelector: &metav1.LabelSelector{
					MatchLabels: h.LabelSelector.MatchLabels,
				},
				Hooks: []velerov1.BackupResourceHook{
					{Exec: &execHook},
				},
			})
		}
	}

	buildHooks(policy.Spec.PreBackupHooks, "pre")
	buildHooks(policy.Spec.PostBackupHooks, "post")
	return specs
}

// pruneOldBackups deletes the oldest Velero backups beyond MaxBackupCount.
func (r *BackupPolicyReconciler) pruneOldBackups(ctx context.Context, policy *BackupPolicy) error {
	logger := log.FromContext(ctx)

	backupList := &velerov1.BackupList{}
	if err := r.List(ctx, backupList,
		client.InNamespace(veleroNamespace),
		client.MatchingLabels{"backup.example.com/policy": policy.Name},
	); err != nil {
		return fmt.Errorf("list backups: %w", err)
	}

	if len(backupList.Items) <= policy.Spec.MaxBackupCount {
		return nil
	}

	// Sort by creation time ascending (oldest first)
	items := backupList.Items
	for i := 0; i < len(items)-1; i++ {
		for j := i + 1; j < len(items); j++ {
			if items[j].CreationTimestamp.Before(&items[i].CreationTimestamp) {
				items[i], items[j] = items[j], items[i]
			}
		}
	}

	toDelete := items[:len(items)-policy.Spec.MaxBackupCount]
	for _, b := range toDelete {
		logger.Info("Pruning old backup", "name", b.Name)
		if err := r.Delete(ctx, &b); err != nil && !errors.IsNotFound(err) {
			return fmt.Errorf("delete backup %s: %w", b.Name, err)
		}
	}
	return nil
}

// syncBackupStatus updates status from the last Velero Backup phase.
func (r *BackupPolicyReconciler) syncBackupStatus(ctx context.Context, policy *BackupPolicy) error {
	if policy.Status.LastBackupName == "" {
		return nil
	}
	backup := &velerov1.Backup{}
	err := r.Get(ctx, client.ObjectKey{
		Name:      policy.Status.LastBackupName,
		Namespace: veleroNamespace,
	}, backup)
	if err != nil {
		if errors.IsNotFound(err) {
			return nil
		}
		return err
	}
	policy.Status.LastBackupPhase = string(backup.Status.Phase)
	return nil
}

// setCondition sets a status condition on the policy.
func (r *BackupPolicyReconciler) setCondition(policy *BackupPolicy, condType string, status metav1.ConditionStatus, reason, message string) {
	now := metav1.Now()
	for i, c := range policy.Status.Conditions {
		if c.Type == condType {
			policy.Status.Conditions[i].Status = status
			policy.Status.Conditions[i].Reason = reason
			policy.Status.Conditions[i].Message = message
			policy.Status.Conditions[i].LastTransitionTime = now
			return
		}
	}
	policy.Status.Conditions = append(policy.Status.Conditions, metav1.Condition{
		Type:               condType,
		Status:             status,
		Reason:             reason,
		Message:            message,
		LastTransitionTime: now,
	})
}

// SetupWithManager registers the controller with the manager.
func (r *BackupPolicyReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&BackupPolicy{}).
		Complete(r)
}

// -----------------------------------------------------------------------------
// Main entrypoint
// -----------------------------------------------------------------------------

func main() {
	log.SetLogger(zap.New(zap.UseDevMode(false)))
	setupLog := log.Log.WithName("setup")

	scheme := runtime.NewScheme()
	_ = corev1.AddToScheme(scheme)
	_ = velerov1.AddToScheme(scheme)
	// Register BackupPolicy CRD scheme:
	// scheme.AddKnownTypes(schema.GroupVersion{Group: "backup.example.com", Version: "v1alpha1"},
	//     &BackupPolicy{}, &BackupPolicyList{})

	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme:                  scheme,
		LeaderElection:          true,
		LeaderElectionID:        "backup-controller-leader",
		LeaderElectionNamespace: "dr-system",
		HealthProbeBindAddress:  ":8081",
		MetricsBindAddress:      ":8080",
	})
	if err != nil {
		setupLog.Error(err, "unable to create manager")
		os.Exit(1)
	}

	if err = (&BackupPolicyReconciler{
		Client: mgr.GetClient(),
		Scheme: mgr.GetScheme(),
	}).SetupWithManager(mgr); err != nil {
		setupLog.Error(err, "unable to create controller", "controller", "BackupPolicy")
		os.Exit(1)
	}

	setupLog.Info("Starting backup controller manager")
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		setupLog.Error(err, "problem running manager")
		os.Exit(1)
	}
}

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

func boolPtr(b bool) *bool { return &b }
