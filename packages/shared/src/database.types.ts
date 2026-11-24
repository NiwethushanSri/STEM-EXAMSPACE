
export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[]

export type Database = {
  
  "graphql_public": {
          Tables: {
            [_ in never]: never
          }
          Views: {
            [_ in never]: never
          }
          Functions: {
            "graphql":
{ Args: { "extensions"?: Json,"operationName"?: string,"query"?: string,"variables"?: Json }; Returns: Json
                           }
          }
          Enums: {
            [_ in never]: never
          }
          CompositeTypes: {
            [_ in never]: never
          }
        },"public": {
          Tables: {
            "attendance": {
                  Row: {
                    "exam_id": string,"marked_at": string,"marked_by": string | null,"status": Database["public"]['Enums']["attendance_status"],"student_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "exam_id": string,"marked_at"?: string,"marked_by"?: string | null,"status": Database["public"]['Enums']["attendance_status"],"student_id": string
                  }
                  Update: {
                    "exam_id"?: string,"marked_at"?: string,"marked_by"?: string | null,"status"?: Database["public"]['Enums']["attendance_status"],"student_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "attendance_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "attendance_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "attendance_marked_by_fkey"
      columns: ["marked_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "attendance_student_id_fkey"
      columns: ["student_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"audit_log": {
                  Row: {
                    "action": string,"actor_id": string | null,"created_at": string,"id": number,"reason": string | null,"target_id": string | null,"target_type": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "action": string,"actor_id"?: string | null,"created_at"?: string,"id"?: never,"reason"?: string | null,"target_id"?: string | null,"target_type"?: string | null
                  }
                  Update: {
                    "action"?: string,"actor_id"?: string | null,"created_at"?: string,"id"?: never,"reason"?: string | null,"target_id"?: string | null,"target_type"?: string | null
                  }
                  Relationships: [
                    
                  ]
                },"bookings": {
                  Row: {
                    "amount_pence": number,"booked_by": string | null,"centre_id": string | null,"created_at": string,"exam_id": string,"hold_expires_at": string | null,"id": string,"notes": string | null,"paid_at": string | null,"paid_offline": boolean,"refund_due": boolean,"refunded_pence": number,"sitting": Database["public"]['Enums']["sitting_mode"],"status": Database["public"]['Enums']["booking_status"],"stripe_checkout_session_id": string | null,"stripe_payment_intent_id": string | null,"student_id": string | null,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "amount_pence": number,"booked_by"?: string | null,"centre_id"?: string | null,"created_at"?: string,"exam_id": string,"hold_expires_at"?: string | null,"id"?: string,"notes"?: string | null,"paid_at"?: string | null,"paid_offline"?: boolean,"refund_due"?: boolean,"refunded_pence"?: number,"sitting": Database["public"]['Enums']["sitting_mode"],"status": Database["public"]['Enums']["booking_status"],"stripe_checkout_session_id"?: string | null,"stripe_payment_intent_id"?: string | null,"student_id"?: string | null,"updated_at"?: string
                  }
                  Update: {
                    "amount_pence"?: number,"booked_by"?: string | null,"centre_id"?: string | null,"created_at"?: string,"exam_id"?: string,"hold_expires_at"?: string | null,"id"?: string,"notes"?: string | null,"paid_at"?: string | null,"paid_offline"?: boolean,"refund_due"?: boolean,"refunded_pence"?: number,"sitting"?: Database["public"]['Enums']["sitting_mode"],"status"?: Database["public"]['Enums']["booking_status"],"stripe_checkout_session_id"?: string | null,"stripe_payment_intent_id"?: string | null,"student_id"?: string | null,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "bookings_booked_by_fkey"
      columns: ["booked_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "bookings_centre_exam_fkey"
      columns: ["centre_id","exam_id"]
isOneToOne: false
      referencedRelation: "exam_centres"
      referencedColumns: ["id","exam_id"]
    },{
      foreignKeyName: "bookings_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "bookings_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "bookings_student_id_fkey"
      columns: ["student_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"collection_counts": {
                  Row: {
                    "booking_id": string,"exam_id": string,"extra_sheets": number,"recorded_at": string,"recorded_by": string
                  }
                  ComputedFields: never
                  Insert: {
                    "booking_id": string,"exam_id": string,"extra_sheets": number,"recorded_at"?: string,"recorded_by": string
                  }
                  Update: {
                    "booking_id"?: string,"exam_id"?: string,"extra_sheets"?: number,"recorded_at"?: string,"recorded_by"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "collection_counts_booking_id_fkey"
      columns: ["booking_id"]
isOneToOne: true
      referencedRelation: "bookings"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "collection_counts_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "collection_counts_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams_public"
      referencedColumns: ["id"]
    }
                  ]
                },"collection_manifests": {
                  Row: {
                    "centre_id": string,"created_at": string,"created_by": string,"exam_id": string,"id": string,"number": string
                  }
                  ComputedFields: never
                  Insert: {
                    "centre_id": string,"created_at"?: string,"created_by": string,"exam_id": string,"id"?: string,"number": string
                  }
                  Update: {
                    "centre_id"?: string,"created_at"?: string,"created_by"?: string,"exam_id"?: string,"id"?: string,"number"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "collection_manifests_centre_id_fkey"
      columns: ["centre_id"]
isOneToOne: false
      referencedRelation: "exam_centres"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "collection_manifests_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "collection_manifests_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams_public"
      referencedColumns: ["id"]
    }
                  ]
                },"custody_events": {
                  Row: {
                    "at": string,"batch_id": string | null,"centre_id": string,"exam_id": string,"from_staff": string | null,"id": string,"location": string,"manifest_id": string | null,"note": string | null,"recorded_by": string,"seq": number,"step": string,"to_staff": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "at"?: string,"batch_id"?: string | null,"centre_id": string,"exam_id": string,"from_staff"?: string | null,"id"?: string,"location": string,"manifest_id"?: string | null,"note"?: string | null,"recorded_by": string,"seq"?: never,"step": string,"to_staff"?: string | null
                  }
                  Update: {
                    "at"?: string,"batch_id"?: string | null,"centre_id"?: string,"exam_id"?: string,"from_staff"?: string | null,"id"?: string,"location"?: string,"manifest_id"?: string | null,"note"?: string | null,"recorded_by"?: string,"seq"?: never,"step"?: string,"to_staff"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "custody_events_batch_id_fkey"
      columns: ["batch_id"]
isOneToOne: false
      referencedRelation: "scan_batches"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "custody_events_centre_id_fkey"
      columns: ["centre_id"]
isOneToOne: false
      referencedRelation: "exam_centres"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "custody_events_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "custody_events_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "custody_events_from_staff_fkey"
      columns: ["from_staff"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "custody_events_manifest_id_fkey"
      columns: ["manifest_id"]
isOneToOne: false
      referencedRelation: "collection_manifests"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "custody_events_to_staff_fkey"
      columns: ["to_staff"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"exam_centres": {
                  Row: {
                    "created_at": string,"exam_id": string,"id": string,"register_closed_at": string | null,"removed_at": string | null,"room": string,"seat_limit": number,"venue_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"exam_id": string,"id"?: string,"register_closed_at"?: string | null,"removed_at"?: string | null,"room": string,"seat_limit": number,"venue_id": string
                  }
                  Update: {
                    "created_at"?: string,"exam_id"?: string,"id"?: string,"register_closed_at"?: string | null,"removed_at"?: string | null,"room"?: string,"seat_limit"?: number,"venue_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "exam_centres_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "exam_centres_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "exam_centres_venue_id_fkey"
      columns: ["venue_id"]
isOneToOne: false
      referencedRelation: "venues"
      referencedColumns: ["id"]
    }
                  ]
                },"exam_mark_scheme_files": {
                  Row: {
                    "byte_size": number,"exam_id": string,"id": string,"removed_at": string | null,"state": string,"storage_path": string,"uploaded_at": string | null,"uploaded_by": string
                  }
                  ComputedFields: never
                  Insert: {
                    "byte_size": number,"exam_id": string,"id"?: string,"removed_at"?: string | null,"state"?: string,"storage_path": string,"uploaded_at"?: string | null,"uploaded_by": string
                  }
                  Update: {
                    "byte_size"?: number,"exam_id"?: string,"id"?: string,"removed_at"?: string | null,"state"?: string,"storage_path"?: string,"uploaded_at"?: string | null,"uploaded_by"?: string
                  }
                  Relationships: [
                    
                  ]
                },"exam_markers": {
                  Row: {
                    "cleared_at": string | null,"cleared_by": string | null,"exam_id": string,"marker_id": string,"misses": number,"pause_applied_at": string | null,"paused_at": string | null,"until_seed": number | null
                  }
                  ComputedFields: never
                  Insert: {
                    "cleared_at"?: string | null,"cleared_by"?: string | null,"exam_id": string,"marker_id": string,"misses"?: number,"pause_applied_at"?: string | null,"paused_at"?: string | null,"until_seed"?: number | null
                  }
                  Update: {
                    "cleared_at"?: string | null,"cleared_by"?: string | null,"exam_id"?: string,"marker_id"?: string,"misses"?: number,"pause_applied_at"?: string | null,"paused_at"?: string | null,"until_seed"?: number | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "exam_markers_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "exam_markers_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "exam_markers_marker_id_fkey"
      columns: ["marker_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"exam_marking": {
                  Row: {
                    "approved_at": string | null,"approved_by": string | null,"checks_off_at": string | null,"checks_off_by": string | null,"checks_off_reason": string | null,"closed_at": string | null,"closed_by": string | null,"deadline": string | null,"double_marking": boolean,"exam_id": string,"mode": Database["public"]['Enums']["marking_mode"],"opened_at": string | null,"opened_by": string | null,"practice": boolean,"sample_percent": number,"seed_every": number,"seeds": boolean,"structure_version": number,"tolerance_percent": number,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "approved_at"?: string | null,"approved_by"?: string | null,"checks_off_at"?: string | null,"checks_off_by"?: string | null,"checks_off_reason"?: string | null,"closed_at"?: string | null,"closed_by"?: string | null,"deadline"?: string | null,"double_marking"?: boolean,"exam_id": string,"mode"?: Database["public"]['Enums']["marking_mode"],"opened_at"?: string | null,"opened_by"?: string | null,"practice"?: boolean,"sample_percent"?: number,"seed_every"?: number,"seeds"?: boolean,"structure_version"?: number,"tolerance_percent"?: number,"updated_at"?: string
                  }
                  Update: {
                    "approved_at"?: string | null,"approved_by"?: string | null,"checks_off_at"?: string | null,"checks_off_by"?: string | null,"checks_off_reason"?: string | null,"closed_at"?: string | null,"closed_by"?: string | null,"deadline"?: string | null,"double_marking"?: boolean,"exam_id"?: string,"mode"?: Database["public"]['Enums']["marking_mode"],"opened_at"?: string | null,"opened_by"?: string | null,"practice"?: boolean,"sample_percent"?: number,"seed_every"?: number,"seeds"?: boolean,"structure_version"?: number,"tolerance_percent"?: number,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "exam_marking_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: true
      referencedRelation: "exams"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "exam_marking_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: true
      referencedRelation: "exams_public"
      referencedColumns: ["id"]
    }
                  ]
                },"exam_option_groups": {
                  Row: {
                    "choose": number,"exam_id": string,"id": string,"label": string
                  }
                  ComputedFields: never
                  Insert: {
                    "choose": number,"exam_id": string,"id"?: string,"label": string
                  }
                  Update: {
                    "choose"?: number,"exam_id"?: string,"id"?: string,"label"?: string
                  }
                  Relationships: [
                    
                  ]
                },"exam_papers": {
                  Row: {
                    "byte_size": number,"corrected_notified_at": string | null,"exam_id": string,"id": string,"kind": Database["public"]['Enums']["paper_kind"],"page_count": number,"pages_reviewed_at": string | null,"replace_reason": string | null,"storage_path": string,"superseded_at": string | null,"title": string,"uploaded_at": string,"uploaded_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "byte_size": number,"corrected_notified_at"?: string | null,"exam_id": string,"id"?: string,"kind": Database["public"]['Enums']["paper_kind"],"page_count": number,"pages_reviewed_at"?: string | null,"replace_reason"?: string | null,"storage_path": string,"superseded_at"?: string | null,"title": string,"uploaded_at"?: string,"uploaded_by"?: string | null,"version": number
                  }
                  Update: {
                    "byte_size"?: number,"corrected_notified_at"?: string | null,"exam_id"?: string,"id"?: string,"kind"?: Database["public"]['Enums']["paper_kind"],"page_count"?: number,"pages_reviewed_at"?: string | null,"replace_reason"?: string | null,"storage_path"?: string,"superseded_at"?: string | null,"title"?: string,"uploaded_at"?: string,"uploaded_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "exam_papers_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "exam_papers_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "exam_papers_uploaded_by_fkey"
      columns: ["uploaded_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"exam_questions": {
                  Row: {
                    "alternatives": string | null,"areas": NonNullable<Json>,"created_at": string,"exam_id": string,"group_id": string | null,"guidance": string | null,"id": string,"label": string,"levels": boolean,"mark_step": number,"max_mark": number | null,"option_group_id": string | null,"pages": (number)[],"parent_id": string | null,"position": number,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "alternatives"?: string | null,"areas"?: NonNullable<Json>,"created_at"?: string,"exam_id": string,"group_id"?: string | null,"guidance"?: string | null,"id"?: string,"label": string,"levels"?: boolean,"mark_step"?: number,"max_mark"?: number | null,"option_group_id"?: string | null,"pages"?: (number)[],"parent_id"?: string | null,"position": number,"updated_at"?: string
                  }
                  Update: {
                    "alternatives"?: string | null,"areas"?: NonNullable<Json>,"created_at"?: string,"exam_id"?: string,"group_id"?: string | null,"guidance"?: string | null,"id"?: string,"label"?: string,"levels"?: boolean,"mark_step"?: number,"max_mark"?: number | null,"option_group_id"?: string | null,"pages"?: (number)[],"parent_id"?: string | null,"position"?: number,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "exam_questions_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "exam_questions_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "exam_questions_group_id_fkey"
      columns: ["group_id"]
isOneToOne: false
      referencedRelation: "question_groups"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "exam_questions_option_group_id_fkey"
      columns: ["option_group_id"]
isOneToOne: false
      referencedRelation: "exam_option_groups"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "exam_questions_parent_id_fkey"
      columns: ["parent_id"]
isOneToOne: false
      referencedRelation: "exam_questions"
      referencedColumns: ["id"]
    }
                  ]
                },"exams": {
                  Row: {
                    "allowed_materials": string | null,"booking_deadline": string,"created_at": string,"created_by": string | null,"currency": string,"duration_minutes": number,"exam_code": string,"format": Database["public"]['Enums']["exam_format"],"home_rules": string | null,"id": string,"paper": string,"price_confirmed": boolean,"price_pence": number,"release_held": boolean,"release_minutes_before": number,"release_notified_at": string | null,"released_early_at": string | null,"spare_pages": number,"starts_at": string,"status": Database["public"]['Enums']["exam_status"],"subject_id": number,"title": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "allowed_materials"?: string | null,"booking_deadline": string,"created_at"?: string,"created_by"?: string | null,"currency"?: string,"duration_minutes": number,"exam_code": string,"format": Database["public"]['Enums']["exam_format"],"home_rules"?: string | null,"id"?: string,"paper": string,"price_confirmed"?: boolean,"price_pence": number,"release_held"?: boolean,"release_minutes_before"?: number,"release_notified_at"?: string | null,"released_early_at"?: string | null,"spare_pages"?: number,"starts_at": string,"status"?: Database["public"]['Enums']["exam_status"],"subject_id": number,"title": string,"updated_at"?: string
                  }
                  Update: {
                    "allowed_materials"?: string | null,"booking_deadline"?: string,"created_at"?: string,"created_by"?: string | null,"currency"?: string,"duration_minutes"?: number,"exam_code"?: string,"format"?: Database["public"]['Enums']["exam_format"],"home_rules"?: string | null,"id"?: string,"paper"?: string,"price_confirmed"?: boolean,"price_pence"?: number,"release_held"?: boolean,"release_minutes_before"?: number,"release_notified_at"?: string | null,"released_early_at"?: string | null,"spare_pages"?: number,"starts_at"?: string,"status"?: Database["public"]['Enums']["exam_status"],"subject_id"?: number,"title"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "exams_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "exams_subject_id_fkey"
      columns: ["subject_id"]
isOneToOne: false
      referencedRelation: "subjects"
      referencedColumns: ["id"]
    }
                  ]
                },"final_mark_history": {
                  Row: {
                    "changed_at": string,"changed_by": string | null,"id": number,"mark": number | null,"not_attempted": boolean,"question_id": string,"reason": string | null,"removed": boolean,"source": string,"unit_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "changed_at"?: string,"changed_by"?: string | null,"id"?: never,"mark"?: number | null,"not_attempted": boolean,"question_id": string,"reason"?: string | null,"removed"?: boolean,"source": string,"unit_id": string
                  }
                  Update: {
                    "changed_at"?: string,"changed_by"?: string | null,"id"?: never,"mark"?: number | null,"not_attempted"?: boolean,"question_id"?: string,"reason"?: string | null,"removed"?: boolean,"source"?: string,"unit_id"?: string
                  }
                  Relationships: [
                    
                  ]
                },"final_marks": {
                  Row: {
                    "mark": number | null,"not_attempted": boolean,"question_id": string,"reason": string | null,"set_at": string,"set_by": string | null,"source": string,"unit_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "mark"?: number | null,"not_attempted"?: boolean,"question_id": string,"reason"?: string | null,"set_at"?: string,"set_by"?: string | null,"source": string,"unit_id": string
                  }
                  Update: {
                    "mark"?: number | null,"not_attempted"?: boolean,"question_id"?: string,"reason"?: string | null,"set_at"?: string,"set_by"?: string | null,"source"?: string,"unit_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "final_marks_unit_id_fkey"
      columns: ["unit_id"]
isOneToOne: false
      referencedRelation: "marking_units"
      referencedColumns: ["id"]
    }
                  ]
                },"home_submissions": {
                  Row: {
                    "blank_confirmed": (number)[],"booking_id": string,"checked_at": string | null,"id": string,"late": boolean,"rejected_reason": string | null,"replaces_all": boolean,"seq": number,"state": Database["public"]['Enums']["submission_state"],"submitted_at": string | null,"submitted_by": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "blank_confirmed"?: (number)[],"booking_id": string,"checked_at"?: string | null,"id"?: string,"late"?: boolean,"rejected_reason"?: string | null,"replaces_all"?: boolean,"seq": number,"state"?: Database["public"]['Enums']["submission_state"],"submitted_at"?: string | null,"submitted_by"?: string | null
                  }
                  Update: {
                    "blank_confirmed"?: (number)[],"booking_id"?: string,"checked_at"?: string | null,"id"?: string,"late"?: boolean,"rejected_reason"?: string | null,"replaces_all"?: boolean,"seq"?: number,"state"?: Database["public"]['Enums']["submission_state"],"submitted_at"?: string | null,"submitted_by"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "home_submissions_booking_id_fkey"
      columns: ["booking_id"]
isOneToOne: false
      referencedRelation: "bookings"
      referencedColumns: ["id"]
    }
                  ]
                },"index_counters": {
                  Row: {
                    "last": number,"year": number
                  }
                  ComputedFields: never
                  Insert: {
                    "last": number,"year": number
                  }
                  Update: {
                    "last"?: number,"year"?: number
                  }
                  Relationships: [
                    
                  ]
                },"login_attempts": {
                  Row: {
                    "attempted_at": string,"key": string
                  }
                  ComputedFields: never
                  Insert: {
                    "attempted_at"?: string,"key": string
                  }
                  Update: {
                    "attempted_at"?: string,"key"?: string
                  }
                  Relationships: [
                    
                  ]
                },"mark_scheme_points": {
                  Row: {
                    "id": string,"label": string | null,"marks": number,"marks_to": number | null,"position": number,"question_id": string,"text": string
                  }
                  ComputedFields: never
                  Insert: {
                    "id"?: string,"label"?: string | null,"marks": number,"marks_to"?: number | null,"position": number,"question_id": string,"text": string
                  }
                  Update: {
                    "id"?: string,"label"?: string | null,"marks"?: number,"marks_to"?: number | null,"position"?: number,"question_id"?: string,"text"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "mark_scheme_points_question_id_fkey"
      columns: ["question_id"]
isOneToOne: false
      referencedRelation: "exam_questions"
      referencedColumns: ["id"]
    }
                  ]
                },"marker_approvals": {
                  Row: {
                    "approved_at": string,"approved_by": string | null,"lead": boolean,"marker_id": string,"subject_id": number
                  }
                  ComputedFields: never
                  Insert: {
                    "approved_at": string,"approved_by"?: string | null,"lead"?: boolean,"marker_id": string,"subject_id": number
                  }
                  Update: {
                    "approved_at"?: string,"approved_by"?: string | null,"lead"?: boolean,"marker_id"?: string,"subject_id"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "marker_approvals_marker_id_fkey"
      columns: ["marker_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "marker_approvals_subject_id_fkey"
      columns: ["subject_id"]
isOneToOne: false
      referencedRelation: "subjects"
      referencedColumns: ["id"]
    }
                  ]
                },"marker_conflicts": {
                  Row: {
                    "marker_id": string,"note": string | null,"recorded_at": string,"recorded_by": string | null,"student_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "marker_id": string,"note"?: string | null,"recorded_at": string,"recorded_by"?: string | null,"student_id": string
                  }
                  Update: {
                    "marker_id"?: string,"note"?: string | null,"recorded_at"?: string,"recorded_by"?: string | null,"student_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "marker_conflicts_marker_id_fkey"
      columns: ["marker_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "marker_conflicts_student_id_fkey"
      columns: ["student_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"marking_alerts": {
                  Row: {
                    "closed_at": string | null,"closed_by": string | null,"created_at": string,"exam_id": string,"id": string,"kind": string,"page_id": string | null,"reason": string | null,"resolution": string | null,"script_id": string,"state": string,"unit_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "closed_at"?: string | null,"closed_by"?: string | null,"created_at"?: string,"exam_id": string,"id"?: string,"kind": string,"page_id"?: string | null,"reason"?: string | null,"resolution"?: string | null,"script_id": string,"state"?: string,"unit_id"?: string | null
                  }
                  Update: {
                    "closed_at"?: string | null,"closed_by"?: string | null,"created_at"?: string,"exam_id"?: string,"id"?: string,"kind"?: string,"page_id"?: string | null,"reason"?: string | null,"resolution"?: string | null,"script_id"?: string,"state"?: string,"unit_id"?: string | null
                  }
                  Relationships: [
                    
                  ]
                },"marking_assignments": {
                  Row: {
                    "assigned_by": string | null,"created_at": string,"end_reason": string | null,"ended_at": string | null,"hold_until": string | null,"how": string,"id": string,"kind": Database["public"]['Enums']["marking_kind"],"marker_id": string,"unit_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "assigned_by"?: string | null,"created_at"?: string,"end_reason"?: string | null,"ended_at"?: string | null,"hold_until"?: string | null,"how": string,"id"?: string,"kind"?: Database["public"]['Enums']["marking_kind"],"marker_id": string,"unit_id": string
                  }
                  Update: {
                    "assigned_by"?: string | null,"created_at"?: string,"end_reason"?: string | null,"ended_at"?: string | null,"hold_until"?: string | null,"how"?: string,"id"?: string,"kind"?: Database["public"]['Enums']["marking_kind"],"marker_id"?: string,"unit_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "marking_assignments_marker_id_fkey"
      columns: ["marker_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "marking_assignments_unit_id_fkey"
      columns: ["unit_id"]
isOneToOne: false
      referencedRelation: "marking_units"
      referencedColumns: ["id"]
    }
                  ]
                },"marking_reviews": {
                  Row: {
                    "closed_at": string | null,"closed_by": string | null,"exam_id": string,"id": string,"kind": string,"marking_id": string,"opened_at": string,"outcome": string | null,"reason": string | null,"second_marking_id": string | null,"state": string,"unit_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "closed_at"?: string | null,"closed_by"?: string | null,"exam_id": string,"id"?: string,"kind": string,"marking_id": string,"opened_at"?: string,"outcome"?: string | null,"reason"?: string | null,"second_marking_id"?: string | null,"state"?: string,"unit_id": string
                  }
                  Update: {
                    "closed_at"?: string | null,"closed_by"?: string | null,"exam_id"?: string,"id"?: string,"kind"?: string,"marking_id"?: string,"opened_at"?: string,"outcome"?: string | null,"reason"?: string | null,"second_marking_id"?: string | null,"state"?: string,"unit_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "marking_reviews_marking_id_fkey"
      columns: ["marking_id"]
isOneToOne: false
      referencedRelation: "markings"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "marking_reviews_second_marking_id_fkey"
      columns: ["second_marking_id"]
isOneToOne: false
      referencedRelation: "markings"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "marking_reviews_unit_id_fkey"
      columns: ["unit_id"]
isOneToOne: false
      referencedRelation: "marking_units"
      referencedColumns: ["id"]
    }
                  ]
                },"marking_standard_marks": {
                  Row: {
                    "mark": number | null,"not_attempted": boolean,"question_id": string,"standard_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "mark"?: number | null,"not_attempted"?: boolean,"question_id": string,"standard_id": string
                  }
                  Update: {
                    "mark"?: number | null,"not_attempted"?: boolean,"question_id"?: string,"standard_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "marking_standard_marks_standard_id_fkey"
      columns: ["standard_id"]
isOneToOne: false
      referencedRelation: "marking_standards"
      referencedColumns: ["id"]
    }
                  ]
                },"marking_standards": {
                  Row: {
                    "created_at": string,"exam_id": string,"id": string,"note": string | null,"retired_at": string | null,"retired_by": string | null,"set_by": string,"unit_id": string,"use": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"exam_id": string,"id"?: string,"note"?: string | null,"retired_at"?: string | null,"retired_by"?: string | null,"set_by": string,"unit_id": string,"use": string
                  }
                  Update: {
                    "created_at"?: string,"exam_id"?: string,"id"?: string,"note"?: string | null,"retired_at"?: string | null,"retired_by"?: string | null,"set_by"?: string,"unit_id"?: string,"use"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "marking_standards_unit_id_fkey"
      columns: ["unit_id"]
isOneToOne: true
      referencedRelation: "marking_units"
      referencedColumns: ["id"]
    }
                  ]
                },"marking_unit_exclusions": {
                  Row: {
                    "created_at": string,"marker_id": string,"reason": string,"unit_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"marker_id": string,"reason": string,"unit_id": string
                  }
                  Update: {
                    "created_at"?: string,"marker_id"?: string,"reason"?: string,"unit_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "marking_unit_exclusions_unit_id_fkey"
      columns: ["unit_id"]
isOneToOne: false
      referencedRelation: "marking_units"
      referencedColumns: ["id"]
    }
                  ]
                },"marking_units": {
                  Row: {
                    "check_state": string | null,"checked_at": string | null,"created_at": string,"exam_id": string,"final_marking_id": string | null,"group_id": string | null,"hold_reason": string | null,"id": string,"on_hold": boolean,"sample_draw": number,"script_id": string,"second_wanted": boolean | null,"state": string
                  }
                  ComputedFields: never
                  Insert: {
                    "check_state"?: string | null,"checked_at"?: string | null,"created_at"?: string,"exam_id": string,"final_marking_id"?: string | null,"group_id"?: string | null,"hold_reason"?: string | null,"id"?: string,"on_hold"?: boolean,"sample_draw"?: number,"script_id": string,"second_wanted"?: boolean | null,"state"?: string
                  }
                  Update: {
                    "check_state"?: string | null,"checked_at"?: string | null,"created_at"?: string,"exam_id"?: string,"final_marking_id"?: string | null,"group_id"?: string | null,"hold_reason"?: string | null,"id"?: string,"on_hold"?: boolean,"sample_draw"?: number,"script_id"?: string,"second_wanted"?: boolean | null,"state"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "marking_units_final_marking_id_fkey"
      columns: ["final_marking_id"]
isOneToOne: false
      referencedRelation: "markings"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "marking_units_group_id_fkey"
      columns: ["group_id"]
isOneToOne: false
      referencedRelation: "question_groups"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "marking_units_script_id_fkey"
      columns: ["script_id"]
isOneToOne: false
      referencedRelation: "scripts"
      referencedColumns: ["id"]
    }
                  ]
                },"markings": {
                  Row: {
                    "active_seconds": number,"feedback_at": string | null,"id": string,"kind": Database["public"]['Enums']["marking_kind"],"last_saved_at": string | null,"lead_note": string | null,"marker_id": string,"pages_changed_at": string | null,"pages_key": string | null,"rev": number,"sent_back_note": string | null,"set_aside_at": string | null,"set_aside_reason": string | null,"started_at": string,"status": string,"structure_version": number | null,"submitted_at": string | null,"total": number | null,"unit_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "active_seconds"?: number,"feedback_at"?: string | null,"id"?: string,"kind"?: Database["public"]['Enums']["marking_kind"],"last_saved_at"?: string | null,"lead_note"?: string | null,"marker_id": string,"pages_changed_at"?: string | null,"pages_key"?: string | null,"rev"?: number,"sent_back_note"?: string | null,"set_aside_at"?: string | null,"set_aside_reason"?: string | null,"started_at"?: string,"status"?: string,"structure_version"?: number | null,"submitted_at"?: string | null,"total"?: number | null,"unit_id": string
                  }
                  Update: {
                    "active_seconds"?: number,"feedback_at"?: string | null,"id"?: string,"kind"?: Database["public"]['Enums']["marking_kind"],"last_saved_at"?: string | null,"lead_note"?: string | null,"marker_id"?: string,"pages_changed_at"?: string | null,"pages_key"?: string | null,"rev"?: number,"sent_back_note"?: string | null,"set_aside_at"?: string | null,"set_aside_reason"?: string | null,"started_at"?: string,"status"?: string,"structure_version"?: number | null,"submitted_at"?: string | null,"total"?: number | null,"unit_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "markings_marker_id_fkey"
      columns: ["marker_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "markings_unit_id_fkey"
      columns: ["unit_id"]
isOneToOne: false
      referencedRelation: "marking_units"
      referencedColumns: ["id"]
    }
                  ]
                },"page_annotations": {
                  Row: {
                    "created_at": string,"deleted_at": string | null,"id": string,"kind": string,"marking_id": string,"page_id": string,"page_rotation": number,"points": Json | null,"question_id": string | null,"text": string | null,"x": number,"y": number
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"deleted_at"?: string | null,"id"?: string,"kind": string,"marking_id": string,"page_id": string,"page_rotation": number,"points"?: Json | null,"question_id"?: string | null,"text"?: string | null,"x": number,"y": number
                  }
                  Update: {
                    "created_at"?: string,"deleted_at"?: string | null,"id"?: string,"kind"?: string,"marking_id"?: string,"page_id"?: string,"page_rotation"?: number,"points"?: Json | null,"question_id"?: string | null,"text"?: string | null,"x"?: number,"y"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "page_annotations_marking_id_fkey"
      columns: ["marking_id"]
isOneToOne: false
      referencedRelation: "markings"
      referencedColumns: ["id"]
    }
                  ]
                },"paper_copies": {
                  Row: {
                    "booking_id": string,"code": string,"created_at": string,"id": string,"page_count": number,"paper_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "booking_id": string,"code": string,"created_at"?: string,"id"?: string,"page_count": number,"paper_id": string
                  }
                  Update: {
                    "booking_id"?: string,"code"?: string,"created_at"?: string,"id"?: string,"page_count"?: number,"paper_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "paper_copies_booking_id_fkey"
      columns: ["booking_id"]
isOneToOne: false
      referencedRelation: "bookings"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "paper_copies_paper_id_fkey"
      columns: ["paper_id"]
isOneToOne: false
      referencedRelation: "exam_papers"
      referencedColumns: ["id"]
    }
                  ]
                },"paper_downloads": {
                  Row: {
                    "at": string,"copy_id": string,"downloaded_by": string | null,"id": number,"kind": Database["public"]['Enums']["paper_download_kind"]
                  }
                  ComputedFields: never
                  Insert: {
                    "at"?: string,"copy_id": string,"downloaded_by"?: string | null,"id"?: never,"kind": Database["public"]['Enums']["paper_download_kind"]
                  }
                  Update: {
                    "at"?: string,"copy_id"?: string,"downloaded_by"?: string | null,"id"?: never,"kind"?: Database["public"]['Enums']["paper_download_kind"]
                  }
                  Relationships: [
                    {
      foreignKeyName: "paper_downloads_copy_id_fkey"
      columns: ["copy_id"]
isOneToOne: false
      referencedRelation: "paper_copies"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "paper_downloads_downloaded_by_fkey"
      columns: ["downloaded_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"paper_hidden_areas": {
                  Row: {
                    "created_at": string,"created_by": string | null,"h": number,"id": string,"page": number,"paper_id": string,"w": number,"x": number,"y": number
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"created_by"?: string | null,"h": number,"id"?: string,"page": number,"paper_id": string,"w": number,"x": number,"y": number
                  }
                  Update: {
                    "created_at"?: string,"created_by"?: string | null,"h"?: number,"id"?: string,"page"?: number,"paper_id"?: string,"w"?: number,"x"?: number,"y"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "paper_hidden_areas_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "paper_hidden_areas_paper_id_fkey"
      columns: ["paper_id"]
isOneToOne: false
      referencedRelation: "exam_papers"
      referencedColumns: ["id"]
    }
                  ]
                },"paper_notices": {
                  Row: {
                    "created_at": string,"done_at": string | null,"exam_id": string,"failed_rounds": number,"id": number,"kind": string,"lease_until": string | null,"paper_ids": (string)[],"release_at": string | null,"retry_at": string | null,"window_until": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"done_at"?: string | null,"exam_id": string,"failed_rounds"?: number,"id"?: never,"kind": string,"lease_until"?: string | null,"paper_ids"?: (string)[],"release_at"?: string | null,"retry_at"?: string | null,"window_until": string
                  }
                  Update: {
                    "created_at"?: string,"done_at"?: string | null,"exam_id"?: string,"failed_rounds"?: number,"id"?: never,"kind"?: string,"lease_until"?: string | null,"paper_ids"?: (string)[],"release_at"?: string | null,"retry_at"?: string | null,"window_until"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "paper_notices_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "paper_notices_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams_public"
      referencedColumns: ["id"]
    }
                  ]
                },"paper_notices_sent": {
                  Row: {
                    "notice_id": number,"profile_id": string,"sent_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "notice_id": number,"profile_id": string,"sent_at"?: string
                  }
                  Update: {
                    "notice_id"?: number,"profile_id"?: string,"sent_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "paper_notices_sent_notice_id_fkey"
      columns: ["notice_id"]
isOneToOne: false
      referencedRelation: "paper_notices"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "paper_notices_sent_profile_id_fkey"
      columns: ["profile_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"paper_page_roles": {
                  Row: {
                    "page": number,"paper_id": string,"role": Database["public"]['Enums']["page_role"]
                  }
                  ComputedFields: never
                  Insert: {
                    "page": number,"paper_id": string,"role": Database["public"]['Enums']["page_role"]
                  }
                  Update: {
                    "page"?: number,"paper_id"?: string,"role"?: Database["public"]['Enums']["page_role"]
                  }
                  Relationships: [
                    {
      foreignKeyName: "paper_page_roles_paper_id_fkey"
      columns: ["paper_id"]
isOneToOne: false
      referencedRelation: "exam_papers"
      referencedColumns: ["id"]
    }
                  ]
                },"parent_children": {
                  Row: {
                    "parent_id": string,"student_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "parent_id": string,"student_id": string
                  }
                  Update: {
                    "parent_id"?: string,"student_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "parent_children_parent_id_fkey"
      columns: ["parent_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "parent_children_student_id_fkey"
      columns: ["student_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"parent_link_blocks": {
                  Row: {
                    "created_at": string,"parent_id": string,"student_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"parent_id": string,"student_id": string
                  }
                  Update: {
                    "created_at"?: string,"parent_id"?: string,"student_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "parent_link_blocks_parent_id_fkey"
      columns: ["parent_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "parent_link_blocks_student_id_fkey"
      columns: ["student_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"parent_link_requests": {
                  Row: {
                    "created_at": string,"id": string,"parent_id": string,"student_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"id"?: string,"parent_id": string,"student_id": string
                  }
                  Update: {
                    "created_at"?: string,"id"?: string,"parent_id"?: string,"student_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "parent_link_requests_parent_id_fkey"
      columns: ["parent_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "parent_link_requests_student_id_fkey"
      columns: ["student_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"pending_invites": {
                  Row: {
                    "created_at": string,"email": string,"invited_by": string | null,"role": Database["public"]['Enums']["app_role"],"token": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"email": string,"invited_by"?: string | null,"role": Database["public"]['Enums']["app_role"],"token"?: string
                  }
                  Update: {
                    "created_at"?: string,"email"?: string,"invited_by"?: string | null,"role"?: Database["public"]['Enums']["app_role"],"token"?: string
                  }
                  Relationships: [
                    
                  ]
                },"processing_jobs": {
                  Row: {
                    "attempts": number,"created_at": string,"finished_at": string | null,"id": number,"kind": string,"last_error": string | null,"locked_at": string | null,"locked_by": string | null,"run_after": string,"state": Database["public"]['Enums']["job_state"],"upload_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "attempts"?: number,"created_at"?: string,"finished_at"?: string | null,"id"?: never,"kind": string,"last_error"?: string | null,"locked_at"?: string | null,"locked_by"?: string | null,"run_after"?: string,"state"?: Database["public"]['Enums']["job_state"],"upload_id": string
                  }
                  Update: {
                    "attempts"?: number,"created_at"?: string,"finished_at"?: string | null,"id"?: never,"kind"?: string,"last_error"?: string | null,"locked_at"?: string | null,"locked_by"?: string | null,"run_after"?: string,"state"?: Database["public"]['Enums']["job_state"],"upload_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "processing_jobs_upload_id_fkey"
      columns: ["upload_id"]
isOneToOne: false
      referencedRelation: "script_uploads"
      referencedColumns: ["id"]
    }
                  ]
                },"profiles": {
                  Row: {
                    "created_at": string,"email": string,"first_name": string,"id": string,"invite_sent_at": string | null,"last_name": string,"role": Database["public"]['Enums']["app_role"],"status": Database["public"]['Enums']["account_status"]
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"email": string,"first_name"?: string,"id": string,"invite_sent_at"?: string | null,"last_name"?: string,"role": Database["public"]['Enums']["app_role"],"status": Database["public"]['Enums']["account_status"]
                  }
                  Update: {
                    "created_at"?: string,"email"?: string,"first_name"?: string,"id"?: string,"invite_sent_at"?: string | null,"last_name"?: string,"role"?: Database["public"]['Enums']["app_role"],"status"?: Database["public"]['Enums']["account_status"]
                  }
                  Relationships: [
                    
                  ]
                },"question_groups": {
                  Row: {
                    "exam_id": string,"id": string,"label": string,"position": number
                  }
                  ComputedFields: never
                  Insert: {
                    "exam_id": string,"id"?: string,"label": string,"position": number
                  }
                  Update: {
                    "exam_id"?: string,"id"?: string,"label"?: string,"position"?: number
                  }
                  Relationships: [
                    
                  ]
                },"question_mark_history": {
                  Row: {
                    "after_submit": boolean,"changed_at": string,"changed_by": string,"id": number,"mark": number | null,"marking_id": string,"not_attempted": boolean,"question_id": string,"reason": string | null,"source": string
                  }
                  ComputedFields: never
                  Insert: {
                    "after_submit": boolean,"changed_at": string,"changed_by": string,"id"?: never,"mark"?: number | null,"marking_id": string,"not_attempted": boolean,"question_id": string,"reason"?: string | null,"source": string
                  }
                  Update: {
                    "after_submit"?: boolean,"changed_at"?: string,"changed_by"?: string,"id"?: never,"mark"?: number | null,"marking_id"?: string,"not_attempted"?: boolean,"question_id"?: string,"reason"?: string | null,"source"?: string
                  }
                  Relationships: [
                    
                  ]
                },"question_marks": {
                  Row: {
                    "mark": number | null,"marking_id": string,"not_attempted": boolean,"question_id": string,"source": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "mark"?: number | null,"marking_id": string,"not_attempted"?: boolean,"question_id": string,"source"?: string,"updated_at"?: string
                  }
                  Update: {
                    "mark"?: number | null,"marking_id"?: string,"not_attempted"?: boolean,"question_id"?: string,"source"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "question_marks_marking_id_fkey"
      columns: ["marking_id"]
isOneToOne: false
      referencedRelation: "markings"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "question_marks_question_id_fkey"
      columns: ["question_id"]
isOneToOne: false
      referencedRelation: "exam_questions"
      referencedColumns: ["id"]
    }
                  ]
                },"scan_batches": {
                  Row: {
                    "centre_id": string,"created_at": string,"created_by": string | null,"exam_id": string,"id": string,"manifest_id": string | null,"number": string,"submitted_at": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "centre_id": string,"created_at"?: string,"created_by"?: string | null,"exam_id": string,"id"?: string,"manifest_id"?: string | null,"number": string,"submitted_at"?: string | null
                  }
                  Update: {
                    "centre_id"?: string,"created_at"?: string,"created_by"?: string | null,"exam_id"?: string,"id"?: string,"manifest_id"?: string | null,"number"?: string,"submitted_at"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "scan_batches_centre_id_fkey"
      columns: ["centre_id"]
isOneToOne: false
      referencedRelation: "exam_centres"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "scan_batches_manifest_id_fkey"
      columns: ["manifest_id"]
isOneToOne: false
      referencedRelation: "collection_manifests"
      referencedColumns: ["id"]
    }
                  ]
                },"script_exceptions": {
                  Row: {
                    "booking_id": string | null,"created_at": string,"details": NonNullable<Json>,"exam_id": string,"id": string,"kind": Database["public"]['Enums']["exception_kind"],"page_id": string | null,"reason": string | null,"resolution": string | null,"resolved_at": string | null,"resolved_by": string | null,"script_id": string | null,"state": string,"upload_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "booking_id"?: string | null,"created_at"?: string,"details"?: NonNullable<Json>,"exam_id": string,"id"?: string,"kind": Database["public"]['Enums']["exception_kind"],"page_id"?: string | null,"reason"?: string | null,"resolution"?: string | null,"resolved_at"?: string | null,"resolved_by"?: string | null,"script_id"?: string | null,"state"?: string,"upload_id"?: string | null
                  }
                  Update: {
                    "booking_id"?: string | null,"created_at"?: string,"details"?: NonNullable<Json>,"exam_id"?: string,"id"?: string,"kind"?: Database["public"]['Enums']["exception_kind"],"page_id"?: string | null,"reason"?: string | null,"resolution"?: string | null,"resolved_at"?: string | null,"resolved_by"?: string | null,"script_id"?: string | null,"state"?: string,"upload_id"?: string | null
                  }
                  Relationships: [
                    
                  ]
                },"script_notices": {
                  Row: {
                    "alert_id": string | null,"attempts": number,"claimed_at": string | null,"created_at": string,"dedupe_key": string | null,"exam_id": string | null,"exception_id": string | null,"exception_kind": string | null,"group_id": string | null,"id": number,"kind": string,"script_id": string | null,"sent_at": string | null,"skipped_at": string | null,"submission_id": string | null,"script_notice_content": Json | null,"script_notice_count": number | null,"script_notice_recipients": Json | null
                  }
                  ComputedFields: "script_notice_content" | "script_notice_count" | "script_notice_recipients"
                  Insert: {
                    "alert_id"?: string | null,"attempts"?: number,"claimed_at"?: string | null,"created_at"?: string,"dedupe_key"?: string | null,"exam_id"?: string | null,"exception_id"?: string | null,"exception_kind"?: string | null,"group_id"?: string | null,"id"?: never,"kind": string,"script_id"?: string | null,"sent_at"?: string | null,"skipped_at"?: string | null,"submission_id"?: string | null
                  }
                  Update: {
                    "alert_id"?: string | null,"attempts"?: number,"claimed_at"?: string | null,"created_at"?: string,"dedupe_key"?: string | null,"exam_id"?: string | null,"exception_id"?: string | null,"exception_kind"?: string | null,"group_id"?: string | null,"id"?: never,"kind"?: string,"script_id"?: string | null,"sent_at"?: string | null,"skipped_at"?: string | null,"submission_id"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "script_notices_alert_id_fkey"
      columns: ["alert_id"]
isOneToOne: false
      referencedRelation: "marking_alerts"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "script_notices_exception_id_fkey"
      columns: ["exception_id"]
isOneToOne: false
      referencedRelation: "script_exceptions"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "script_notices_script_id_fkey"
      columns: ["script_id"]
isOneToOne: false
      referencedRelation: "scripts"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "script_notices_submission_id_fkey"
      columns: ["submission_id"]
isOneToOne: false
      referencedRelation: "home_submissions"
      referencedColumns: ["id"]
    }
                  ]
                },"script_notices_sent": {
                  Row: {
                    "notice_id": number,"profile_id": string,"sent_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "notice_id": number,"profile_id": string,"sent_at"?: string
                  }
                  Update: {
                    "notice_id"?: number,"profile_id"?: string,"sent_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "script_notices_sent_notice_id_fkey"
      columns: ["notice_id"]
isOneToOne: false
      referencedRelation: "script_notices"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "script_notices_sent_profile_id_fkey"
      columns: ["profile_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"script_page_hidden_areas": {
                  Row: {
                    "created_at": string,"created_by": string | null,"h": number,"id": string,"page_id": string,"w": number,"x": number,"y": number
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"created_by"?: string | null,"h": number,"id"?: string,"page_id": string,"w": number,"x": number,"y": number
                  }
                  Update: {
                    "created_at"?: string,"created_by"?: string | null,"h"?: number,"id"?: string,"page_id"?: string,"w"?: number,"x"?: number,"y"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "script_page_hidden_areas_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "script_page_hidden_areas_page_id_fkey"
      columns: ["page_id"]
isOneToOne: false
      referencedRelation: "script_pages"
      referencedColumns: ["id"]
    }
                  ]
                },"script_page_links": {
                  Row: {
                    "copy_page": number,"page_id": string,"script_id": string,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "copy_page": number,"page_id": string,"script_id": string,"version": number
                  }
                  Update: {
                    "copy_page"?: number,"page_id"?: string,"script_id"?: string,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "script_page_links_page_id_fkey"
      columns: ["page_id"]
isOneToOne: false
      referencedRelation: "script_pages"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "script_page_links_script_id_fkey"
      columns: ["script_id"]
isOneToOne: false
      referencedRelation: "scripts"
      referencedColumns: ["id"]
    }
                  ]
                },"script_pages": {
                  Row: {
                    "blank": boolean,"booking_id": string | null,"copy_id": string | null,"copy_page": number | null,"created_at": string,"exam_id": string,"full_path": string,"full_rotation": number,"id": string,"marking_checked_at": string | null,"marking_checked_by": string | null,"marking_checked_path": string | null,"marking_inputs": string | null,"marking_path": string | null,"placed_after": number | null,"quality": NonNullable<Json>,"replaced_at": string | null,"rotation": number,"source_index": number,"state": Database["public"]['Enums']["page_state"],"upload_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "blank"?: boolean,"booking_id"?: string | null,"copy_id"?: string | null,"copy_page"?: number | null,"created_at"?: string,"exam_id": string,"full_path": string,"full_rotation"?: number,"id"?: string,"marking_checked_at"?: string | null,"marking_checked_by"?: string | null,"marking_checked_path"?: string | null,"marking_inputs"?: string | null,"marking_path"?: string | null,"placed_after"?: number | null,"quality"?: NonNullable<Json>,"replaced_at"?: string | null,"rotation"?: number,"source_index": number,"state": Database["public"]['Enums']["page_state"],"upload_id": string
                  }
                  Update: {
                    "blank"?: boolean,"booking_id"?: string | null,"copy_id"?: string | null,"copy_page"?: number | null,"created_at"?: string,"exam_id"?: string,"full_path"?: string,"full_rotation"?: number,"id"?: string,"marking_checked_at"?: string | null,"marking_checked_by"?: string | null,"marking_checked_path"?: string | null,"marking_inputs"?: string | null,"marking_path"?: string | null,"placed_after"?: number | null,"quality"?: NonNullable<Json>,"replaced_at"?: string | null,"rotation"?: number,"source_index"?: number,"state"?: Database["public"]['Enums']["page_state"],"upload_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "script_pages_booking_id_fkey"
      columns: ["booking_id"]
isOneToOne: false
      referencedRelation: "bookings"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "script_pages_copy_id_fkey"
      columns: ["copy_id"]
isOneToOne: false
      referencedRelation: "paper_copies"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "script_pages_marking_checked_by_fkey"
      columns: ["marking_checked_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "script_pages_upload_id_fkey"
      columns: ["upload_id"]
isOneToOne: false
      referencedRelation: "script_uploads"
      referencedColumns: ["id"]
    }
                  ]
                },"script_uploads": {
                  Row: {
                    "batch_id": string | null,"booking_id": string | null,"byte_size": number,"created_at": string,"discarded_at": string | null,"exam_id": string,"id": string,"kind": Database["public"]['Enums']["upload_kind"],"mime": string,"position": number | null,"purged_at": string | null,"sha256": string | null,"state": Database["public"]['Enums']["upload_state"],"storage_path": string,"stored_at": string | null,"submission_id": string | null,"uploaded_by": string
                  }
                  ComputedFields: never
                  Insert: {
                    "batch_id"?: string | null,"booking_id"?: string | null,"byte_size": number,"created_at"?: string,"discarded_at"?: string | null,"exam_id": string,"id"?: string,"kind": Database["public"]['Enums']["upload_kind"],"mime": string,"position"?: number | null,"purged_at"?: string | null,"sha256"?: string | null,"state"?: Database["public"]['Enums']["upload_state"],"storage_path": string,"stored_at"?: string | null,"submission_id"?: string | null,"uploaded_by": string
                  }
                  Update: {
                    "batch_id"?: string | null,"booking_id"?: string | null,"byte_size"?: number,"created_at"?: string,"discarded_at"?: string | null,"exam_id"?: string,"id"?: string,"kind"?: Database["public"]['Enums']["upload_kind"],"mime"?: string,"position"?: number | null,"purged_at"?: string | null,"sha256"?: string | null,"state"?: Database["public"]['Enums']["upload_state"],"storage_path"?: string,"stored_at"?: string | null,"submission_id"?: string | null,"uploaded_by"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "script_uploads_batch_id_fkey"
      columns: ["batch_id"]
isOneToOne: false
      referencedRelation: "scan_batches"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "script_uploads_submission_id_fkey"
      columns: ["submission_id"]
isOneToOne: false
      referencedRelation: "home_submissions"
      referencedColumns: ["id"]
    }
                  ]
                },"script_versions": {
                  Row: {
                    "created_at": string,"created_by": string | null,"reason": string | null,"script_id": string,"submission_id": string | null,"upload_id": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"created_by"?: string | null,"reason"?: string | null,"script_id": string,"submission_id"?: string | null,"upload_id"?: string | null,"version": number
                  }
                  Update: {
                    "created_at"?: string,"created_by"?: string | null,"reason"?: string | null,"script_id"?: string,"submission_id"?: string | null,"upload_id"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "script_versions_script_id_fkey"
      columns: ["script_id"]
isOneToOne: false
      referencedRelation: "scripts"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "script_versions_submission_id_fkey"
      columns: ["submission_id"]
isOneToOne: false
      referencedRelation: "home_submissions"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "script_versions_upload_id_fkey"
      columns: ["upload_id"]
isOneToOne: false
      referencedRelation: "script_uploads"
      referencedColumns: ["id"]
    }
                  ]
                },"scripts": {
                  Row: {
                    "attention_notified_at": string | null,"booking_id": string,"complete": boolean,"created_at": string,"exam_id": string,"extras_locked": Json | null,"id": string,"late": boolean,"late_decision": string | null,"number": string,"received_at": string | null,"source": Database["public"]['Enums']["script_source"],"state": Database["public"]['Enums']["script_state"],"state_reason": string | null,"taken_back_at": string | null,"taken_back_by": string | null,"taken_back_reason": string | null,"updated_at": string,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "attention_notified_at"?: string | null,"booking_id": string,"complete"?: boolean,"created_at"?: string,"exam_id": string,"extras_locked"?: Json | null,"id"?: string,"late"?: boolean,"late_decision"?: string | null,"number": string,"received_at"?: string | null,"source": Database["public"]['Enums']["script_source"],"state"?: Database["public"]['Enums']["script_state"],"state_reason"?: string | null,"taken_back_at"?: string | null,"taken_back_by"?: string | null,"taken_back_reason"?: string | null,"updated_at"?: string,"version"?: number
                  }
                  Update: {
                    "attention_notified_at"?: string | null,"booking_id"?: string,"complete"?: boolean,"created_at"?: string,"exam_id"?: string,"extras_locked"?: Json | null,"id"?: string,"late"?: boolean,"late_decision"?: string | null,"number"?: string,"received_at"?: string | null,"source"?: Database["public"]['Enums']["script_source"],"state"?: Database["public"]['Enums']["script_state"],"state_reason"?: string | null,"taken_back_at"?: string | null,"taken_back_by"?: string | null,"taken_back_reason"?: string | null,"updated_at"?: string,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "scripts_booking_id_fkey"
      columns: ["booking_id"]
isOneToOne: true
      referencedRelation: "bookings"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "scripts_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "scripts_exam_id_fkey"
      columns: ["exam_id"]
isOneToOne: false
      referencedRelation: "exams_public"
      referencedColumns: ["id"]
    }
                  ]
                },"sitting_acknowledgements": {
                  Row: {
                    "acknowledged_by": string,"as_role": string,"at": string,"booking_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "acknowledged_by": string,"as_role": string,"at": string,"booking_id": string
                  }
                  Update: {
                    "acknowledged_by"?: string,"as_role"?: string,"at"?: string,"booking_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "sitting_acknowledgements_acknowledged_by_fkey"
      columns: ["acknowledged_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "sitting_acknowledgements_booking_id_fkey"
      columns: ["booking_id"]
isOneToOne: true
      referencedRelation: "bookings"
      referencedColumns: ["id"]
    }
                  ]
                },"student_details": {
                  Row: {
                    "date_of_birth": string | null,"gender": string | null,"index_number": string | null,"parent_phone": string | null,"photo_path": string | null,"profile_id": string,"requested_by_parent": string | null,"school": string | null,"signup_parent_email": string | null,"signup_parent_name": string | null,"year_group": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "date_of_birth"?: string | null,"gender"?: string | null,"index_number"?: string | null,"parent_phone"?: string | null,"photo_path"?: string | null,"profile_id": string,"requested_by_parent"?: string | null,"school"?: string | null,"signup_parent_email"?: string | null,"signup_parent_name"?: string | null,"year_group"?: string | null
                  }
                  Update: {
                    "date_of_birth"?: string | null,"gender"?: string | null,"index_number"?: string | null,"parent_phone"?: string | null,"photo_path"?: string | null,"profile_id"?: string,"requested_by_parent"?: string | null,"school"?: string | null,"signup_parent_email"?: string | null,"signup_parent_name"?: string | null,"year_group"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "student_details_profile_id_fkey"
      columns: ["profile_id"]
isOneToOne: true
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "student_details_requested_by_parent_fkey"
      columns: ["requested_by_parent"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"student_subjects": {
                  Row: {
                    "student_id": string,"subject_id": number
                  }
                  ComputedFields: never
                  Insert: {
                    "student_id": string,"subject_id": number
                  }
                  Update: {
                    "student_id"?: string,"subject_id"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "student_subjects_student_id_fkey"
      columns: ["student_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "student_subjects_subject_id_fkey"
      columns: ["subject_id"]
isOneToOne: false
      referencedRelation: "subjects"
      referencedColumns: ["id"]
    }
                  ]
                },"subjects": {
                  Row: {
                    "active": boolean,"id": number,"kind": Database["public"]['Enums']["subject_kind"],"name": string
                  }
                  ComputedFields: never
                  Insert: {
                    "active"?: boolean,"id"?: never,"kind": Database["public"]['Enums']["subject_kind"],"name": string
                  }
                  Update: {
                    "active"?: boolean,"id"?: never,"kind"?: Database["public"]['Enums']["subject_kind"],"name"?: string
                  }
                  Relationships: [
                    
                  ]
                },"teacher_subjects": {
                  Row: {
                    "subject_id": number,"teacher_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "subject_id": number,"teacher_id": string
                  }
                  Update: {
                    "subject_id"?: number,"teacher_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "teacher_subjects_subject_id_fkey"
      columns: ["subject_id"]
isOneToOne: false
      referencedRelation: "subjects"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "teacher_subjects_teacher_id_fkey"
      columns: ["teacher_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"tutor_students": {
                  Row: {
                    "student_id": string,"tutor_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "student_id": string,"tutor_id": string
                  }
                  Update: {
                    "student_id"?: string,"tutor_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "tutor_students_student_id_fkey"
      columns: ["student_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "tutor_students_tutor_id_fkey"
      columns: ["tutor_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"venues": {
                  Row: {
                    "active": boolean,"created_at": string,"id": string,"name": string,"rooms": (string)[]
                  }
                  ComputedFields: never
                  Insert: {
                    "active"?: boolean,"created_at"?: string,"id"?: string,"name": string,"rooms"?: (string)[]
                  }
                  Update: {
                    "active"?: boolean,"created_at"?: string,"id"?: string,"name"?: string,"rooms"?: (string)[]
                  }
                  Relationships: [
                    
                  ]
                }
          }
          Views: {
            "exams_public": {
                  Row: {
                    "booking_deadline": string,"centres": Json | null,"duration_minutes": number,"format": Database["public"]['Enums']["exam_format"],"id": string,"paper": string,"price_pence": number,"seats_left": number | null,"starts_at": string,"subject": string,"title": string
                  }
                  ComputedFields: never
                  Relationships: [
                    
                  ]
                }
          }
          Functions: {
            "admin_add_booking":
{ Args: { "p_centre"?: string,"p_exam": string,"p_note": string,"p_paid": boolean,"p_sitting"?: Database["public"]['Enums']["sitting_mode"],"p_student": string }; Returns: Json
                           },
"approve_student_tx":
{ Args: { "p_actor": string,"p_student": string,"p_year"?: number }; Returns: {
              "index_number": string,"invite_token": string,"parent_email": string,"parent_id": string
            }[]
                           },
"attendance_can_manage":
{ Args: { "p_actor": string,"p_subject": number }; Returns: boolean
                           },
"attendance_lookup":
{ Args: { "p_centre": string,"p_index": string }; Returns: Json
                           },
"attendance_lookup_as":
{ Args: { "p_actor": string,"p_centre": string,"p_index": string }; Returns: Json
                           },
"booking_create_as":
{ Args: { "p_actor": string,"p_centre"?: string,"p_exam": string,"p_now": string,"p_sitting"?: Database["public"]['Enums']["sitting_mode"],"p_student": string }; Returns: Json
                           },
"booking_create_core":
{ Args: { "p_by": string,"p_centre": string,"p_enforce_deadline": boolean,"p_exam": string,"p_note": string,"p_now": string,"p_paid": boolean,"p_sitting": Database["public"]['Enums']["sitting_mode"],"p_student": string }; Returns: Json
                           },
"booking_paper_state":
{ Args: { "p_booking": string,"p_now"?: string }; Returns: Json
                           },
"booking_sitting_state":
{ Args: { "p_booking": string,"p_now"?: string }; Returns: Json
                           },
"can_manage_account":
{ Args: { "p_action": string,"p_actor": string,"p_target": string }; Returns: string
                           },
"can_reject_student":
{ Args: { "p_student": string }; Returns: string
                           },
"cancel_booking_admin":
{ Args: { "p_booking": string,"p_note": string }; Returns: Json
                           },
"centre_seats_taken":
{ Args: { "p_centre": string }; Returns: number
                           },
"change_booking_sitting":
{ Args: { "p_booking": string,"p_centre": string,"p_reason": string,"p_sitting": Database["public"]['Enums']["sitting_mode"] }; Returns: Json
                           },
"claim_invite":
{ Args: { "p_email": string,"p_role": Database["public"]['Enums']["app_role"],"p_token": string,"p_user": string }; Returns: string
                           },
"clear_invite_tx":
{ Args: { "p_actor": string,"p_email": string }; Returns: string
                           },
"close_register":
{ Args: { "p_centre": string }; Returns: Json
                           },
"close_register_as":
{ Args: { "p_actor": string,"p_centre": string,"p_now": string }; Returns: Json
                           },
"collection_list":
{ Args: { "p_centre": string,"p_exam": string }; Returns: Json
                           },
"collection_manifest_create":
{ Args: { "p_centre": string,"p_exam": string }; Returns: Json
                           },
"collection_record":
{ Args: { "p_booking": string,"p_extra_sheets": number }; Returns: Json
                           },
"complete_finished_exams":
{ Args: { "p_now"?: string }; Returns: number
                           },
"complete_profile":
{ Args: { "p_gender": string,"p_parent_phone": string,"p_photo_path"?: string,"p_subject_ids": (number)[],"p_year_group": string }; Returns: undefined
                           },
"copy_code_new":
{ Args: Record<PropertyKey, never>; Returns: string
                           },
"copy_code_valid":
{ Args: { "p_code": string }; Returns: boolean
                           },
"create_booking":
{ Args: { "p_centre"?: string,"p_exam": string,"p_sitting"?: Database["public"]['Enums']["sitting_mode"],"p_student": string }; Returns: Json
                           },
"custody_list":
{ Args: { "p_centre": string,"p_exam": string }; Returns: Json
                           },
"custody_record":
{ Args: { "p_centre": string,"p_exam": string,"p_from": string,"p_location": string,"p_manifest"?: string,"p_note": string,"p_step": string,"p_to": string }; Returns: Json
                           },
"custody_staff":
{ Args: { "p_centre": string,"p_exam": string }; Returns: Json
                           },
"decide_cancellation":
{ Args: { "p_approve": boolean,"p_booking": string,"p_note": string,"p_refund_pence": number }; Returns: Json
                           },
"decide_parent_link_tx":
{ Args: { "p_actor": string,"p_approve": boolean,"p_request": string }; Returns: string
                           },
"delete_account_tx":
{ Args: { "p_actor": string,"p_target": string }; Returns: string
                           },
"delete_own_account_tx":
{ Args: { "p_user": string }; Returns: string
                           },
"edit_parent_email_tx":
{ Args: { "p_actor": string,"p_email": string,"p_target": string }; Returns: string
                           },
"exam_code_base":
{ Args: { "p_paper": string,"p_starts_at": string,"p_subject": number }; Returns: string
                           },
"exam_code_generate":
{ Args: { "p_paper": string,"p_self": string,"p_starts_at": string,"p_subject": number }; Returns: string
                           },
"exam_structure_get":
{ Args: { "p_exam": string }; Returns: Json
                           },
"exam_structure_max_total":
{ Args: { "p_exam": string }; Returns: number
                           },
"exam_structure_pages":
{ Args: { "p_exam": string }; Returns: (number)[]
                           },
"exam_structure_save":
{ Args: { "p_exam": string,"p_reason"?: string,"p_structure": Json }; Returns: Json
                           },
"exam_structure_valid":
{ Args: { "p_pages": (number)[],"p_structure": Json }; Returns: boolean
                           },
"expire_unconfirmed":
{ Args: { "p_now"?: string }; Returns: number
                           },
"expire_unpaid_bookings":
{ Args: { "p_now"?: string }; Returns: number
                           },
"family_has_booking":
{ Args: { "p_exam": string }; Returns: boolean
                           },
"home_booking_lock":
{ Args: { "p_booking": string }; Returns: undefined
                           },
"home_drafts_stored":
{ Args: { "p_now": string }; Returns: {
              "booking_id": string,"exam_id": string,"files": number,"last_file_at": string,"late": boolean,"submission_id": string
            }[]
                           },
"home_drafts_unsubmitted":
{ Args: { "p_exam"?: string,"p_now"?: string }; Returns: Json
                           },
"home_missing_confirm_blank":
{ Args: { "p_pages": (number)[],"p_submission": string }; Returns: Json
                           },
"home_missing_pages":
{ Args: { "p_skip_confirmed": boolean,"p_submission": string }; Returns: (number)[]
                           },
"home_page_place":
{ Args: { "p_after_page": number,"p_page": string }; Returns: Json
                           },
"home_page_send_as_is":
{ Args: { "p_page": string }; Returns: Json
                           },
"home_reevaluate":
{ Args: { "p_booking": string,"p_submission": string }; Returns: Database["public"]['Enums']["submission_state"]
                           },
"home_submission_accept_draft":
{ Args: { "p_now"?: string,"p_reason": string,"p_submission": string }; Returns: Json
                           },
"home_submission_assemble":
{ Args: { "p_now": string,"p_submission": string,"p_upload": string }; Returns: boolean
                           },
"home_submission_evaluate":
{ Args: { "p_now": string,"p_submission": string }; Returns: Database["public"]['Enums']["submission_state"]
                           },
"home_submission_latest":
{ Args: { "p_booking": string }; Returns: {
              "blank_confirmed": (number)[],
"booking_id": string,
"checked_at": string | null,
"id": string,
"late": boolean,
"rejected_reason": string | null,
"replaces_all": boolean,
"seq": number,
"state": Database["public"]['Enums']["submission_state"],
"submitted_at": string | null,
"submitted_by": string | null
            }
                          SetofOptions: {
        from: "*"
        to: "home_submissions"
        isOneToOne: true
        isSetofReturn: false
      } },
"home_submission_open":
{ Args: { "p_booking": string,"p_now"?: string,"p_replaces_all"?: boolean }; Returns: Json
                           },
"home_submission_result":
{ Args: { "p_submission": string }; Returns: Json
                           },
"home_submission_send":
{ Args: { "p_actor": string,"p_now": string,"p_submission": string }; Returns: undefined
                           },
"home_submission_status":
{ Args: { "p_booking": string }; Returns: Json
                           },
"home_submission_submit":
{ Args: { "p_now"?: string,"p_submission": string }; Returns: Json
                           },
"home_upload_code":
{ Args: { "p_actor": string,"p_at": string,"p_booking": Omit<Database["public"]['Tables']["bookings"]['Row'], Database["public"]['Tables']["bookings"]['ComputedFields']> }; Returns: string
                           },
"home_upload_max_bytes":
{ Args: { "p_kind": Database["public"]['Enums']["upload_kind"] }; Returns: number
                           },
"home_upload_type_ok":
{ Args: { "p_kind": Database["public"]['Enums']["upload_kind"],"p_mime": string }; Returns: boolean
                           },
"is_lead_for":
{ Args: { "p_subject": number,"p_user": string }; Returns: boolean
                           },
"is_marker_for":
{ Args: { "p_subject": number,"p_user": string }; Returns: boolean
                           },
"is_staff_admin":
{ Args: Record<PropertyKey, never>; Returns: boolean
                           },
"link_children_to_parent":
{ Args: { "p_parent": string }; Returns: number
                           },
"link_student_to_parent":
{ Args: { "p_parent": string,"p_student": string }; Returns: string
                           },
"login_attempt_begin":
{ Args: { "p_idx_key": string,"p_ip_key": string }; Returns: boolean
                           },
"login_attempt_begin_n":
{ Args: { "p_key_a": string,"p_key_b": string,"p_limit_a": number,"p_limit_b": number }; Returns: boolean
                           },
"login_attempt_refund":
{ Args: { "p_idx_key": string,"p_ip_key": string }; Returns: undefined
                           },
"login_attempt_refund_key":
{ Args: { "p_key": string }; Returns: undefined
                           },
"login_attempt_succeed":
{ Args: { "p_idx_key": string,"p_ip_key": string }; Returns: undefined
                           },
"mark_attendance":
{ Args: { "p_centre": string,"p_student": string }; Returns: Json
                           },
"mark_attendance_as":
{ Args: { "p_actor": string,"p_centre": string,"p_now": string,"p_student": string }; Returns: Json
                           },
"mark_booking_paid":
{ Args: { "p_booking": string,"p_note": string }; Returns: Json
                           },
"mark_scheme_file_begin":
{ Args: { "p_bytes": number,"p_exam": string }; Returns: Json
                           },
"mark_scheme_file_can_change":
{ Args: { "p_exam": string,"p_user": string }; Returns: boolean
                           },
"mark_scheme_file_remove":
{ Args: { "p_file": string,"p_reason": string }; Returns: Json
                           },
"mark_scheme_file_stored":
{ Args: { "p_file": string }; Returns: Json
                           },
"mark_scheme_path_allowed":
{ Args: { "p_name": string }; Returns: boolean
                           },
"mark_scheme_upload_allowed":
{ Args: { "p_name": string }; Returns: boolean
                           },
"marker_approve":
{ Args: { "p_marker": string,"p_reason": string,"p_subject": number }; Returns: Json
                           },
"marker_audit_reason":
{ Args: { "p_detail": string,"p_reason": string }; Returns: string
                           },
"marker_conflict_candidates":
{ Args: { "p_query": string }; Returns: Json
                           },
"marker_conflict_remove":
{ Args: { "p_marker": string,"p_reason": string,"p_student": string }; Returns: Json
                           },
"marker_conflict_set":
{ Args: { "p_marker": string,"p_note": string,"p_reason": string,"p_student": string }; Returns: Json
                           },
"marker_set_lead":
{ Args: { "p_marker": string,"p_reason": string,"p_subject": number }; Returns: Json
                           },
"marker_unapprove":
{ Args: { "p_marker": string,"p_reason": string,"p_subject": number }; Returns: Json
                           },
"markers_list":
{ Args: Record<PropertyKey, never>; Returns: Json
                           },
"marking_after_change":
{ Args: { "p_marking": string }; Returns: undefined
                           },
"marking_after_submit":
{ Args: { "p_marking": string }; Returns: string
                           },
"marking_alert_can_release":
{ Args: { "p_script": string }; Returns: string
                           },
"marking_alert_note":
{ Args: { "p_alert": string,"p_reason": string }; Returns: Json
                           },
"marking_alert_pages":
{ Args: { "p_alert": string }; Returns: Json
                           },
"marking_alert_raise":
{ Args: { "p_kind": string,"p_page": string,"p_script": string,"p_unit": string }; Returns: string
                           },
"marking_alert_release":
{ Args: { "p_alert": string,"p_reason": string }; Returns: Json
                           },
"marking_alerts_list":
{ Args: { "p_exam"?: string,"p_state"?: string }; Returns: Json
                           },
"marking_alerts_release_all":
{ Args: { "p_exam": string,"p_reason": string }; Returns: Json
                           },
"marking_assign":
{ Args: { "p_kind"?: Database["public"]['Enums']["marking_kind"],"p_marker": string,"p_reason": string,"p_units": (string)[] }; Returns: Json
                           },
"marking_assign_some":
{ Args: { "p_count": number,"p_exam": string,"p_group": string,"p_marker": string,"p_reason": string }; Returns: Json
                           },
"marking_check_evaluate":
{ Args: { "p_unit": string }; Returns: string
                           },
"marking_check_exam":
{ Args: { "p_exam": string }; Returns: number
                           },
"marking_checks_get":
{ Args: { "p_exam": string }; Returns: Json
                           },
"marking_checks_set":
{ Args: { "p_exam": string,"p_reason"?: string,"p_settings": Json }; Returns: Json
                           },
"marking_close":
{ Args: { "p_exam": string,"p_reason": string }; Returns: Json
                           },
"marking_compare":
{ Args: { "p_first": string,"p_second": string }; Returns: Json
                           },
"marking_compare_sets":
{ Args: { "p_a": Json,"p_b": Json,"p_unit": string }; Returns: Json
                           },
"marking_dashboard":
{ Args: { "p_now"?: string }; Returns: Json
                           },
"marking_exam_get":
{ Args: { "p_exam": string,"p_now"?: string }; Returns: Json
                           },
"marking_exam_markers":
{ Args: { "p_exam": string }; Returns: Json
                           },
"marking_exam_overdue":
{ Args: { "p_exam": string,"p_now": string }; Returns: boolean
                           },
"marking_exam_sync":
{ Args: { "p_exam": string,"p_now": string }; Returns: number
                           },
"marking_feedback":
{ Args: { "p_marking": string }; Returns: Json
                           },
"marking_final_marks_from":
{ Args: { "p_marking": string,"p_reason": string,"p_unit": string }; Returns: undefined
                           },
"marking_final_marks_lead":
{ Args: { "p_marks": Json,"p_reason": string,"p_unit": string }; Returns: undefined
                           },
"marking_final_marks_remove":
{ Args: { "p_reason": string,"p_unit": string }; Returns: undefined
                           },
"marking_final_set":
{ Args: { "p_marks": Json,"p_reason": string,"p_unit": string }; Returns: Json
                           },
"marking_give_back":
{ Args: { "p_reason"?: string,"p_unit": string }; Returns: Json
                           },
"marking_holds_expire":
{ Args: { "p_now": string }; Returns: number
                           },
"marking_lead_marks_refusal":
{ Args: { "p_every": boolean,"p_marks": Json,"p_unit": string }; Returns: Json
                           },
"marking_marker_blocked":
{ Args: { "p_marker": string,"p_student": string }; Returns: boolean
                           },
"marking_marker_clear":
{ Args: { "p_exam": string,"p_marker": string,"p_reason": string }; Returns: Json
                           },
"marking_marker_cleared":
{ Args: { "p_exam": string,"p_marker": string }; Returns: boolean
                           },
"marking_marker_pause":
{ Args: { "p_exam": string,"p_marker": string,"p_reason": string }; Returns: Json
                           },
"marking_marker_paused":
{ Args: { "p_exam": string,"p_marker": string }; Returns: boolean
                           },
"marking_mask_key":
{ Args: { "p_copy": string,"p_copy_page": number,"p_page": string,"p_rotation": number }; Returns: string
                           },
"marking_missing":
{ Args: { "p_marking": string,"p_unit": string }; Returns: Json
                           },
"marking_my_work":
{ Args: { "p_now"?: string }; Returns: Json
                           },
"marking_name_visible":
{ Args: { "p_page": string,"p_unit": string }; Returns: Json
                           },
"marking_next":
{ Args: { "p_exam": string,"p_group"?: string,"p_now"?: string }; Returns: Json
                           },
"marking_open":
{ Args: { "p_exam": string }; Returns: Json
                           },
"marking_ops_apply":
{ Args: { "p_actor": string,"p_after": boolean,"p_marking": string,"p_ops": Json,"p_reason": string,"p_script": string,"p_unit": string }; Returns: undefined
                           },
"marking_pages_key":
{ Args: { "p_script": string }; Returns: string
                           },
"marking_pass":
{ Args: { "p_marker": string,"p_unit": string }; Returns: {
              "assignment_id": string,"hold_until": string,"how": string,"kind": Database["public"]['Enums']["marking_kind"],"marking_id": string,"status": string
            }[]
                           },
"marking_pause_apply":
{ Args: { "p_exam": string,"p_marker": string }; Returns: number
                           },
"marking_picture_paths":
{ Args: { "p_now"?: string,"p_pages": (string)[],"p_unit": string }; Returns: Json
                           },
"marking_progress":
{ Args: { "p_exam"?: string,"p_now"?: string }; Returns: Json
                           },
"marking_reassign":
{ Args: { "p_marker": string,"p_reason": string,"p_units": (string)[] }; Returns: Json
                           },
"marking_reopen":
{ Args: { "p_exam": string,"p_reason": string }; Returns: Json
                           },
"marking_review_accept":
{ Args: { "p_reason"?: string,"p_review": string }; Returns: Json
                           },
"marking_review_blind":
{ Args: { "p_unit": string }; Returns: boolean
                           },
"marking_review_list":
{ Args: { "p_exam"?: string,"p_kind"?: string }; Returns: Json
                           },
"marking_review_marking":
{ Args: { "p_marking": string }; Returns: Json
                           },
"marking_review_open":
{ Args: { "p_review": string }; Returns: Json
                           },
"marking_review_refusal":
{ Args: { "p_unit": string }; Returns: string
                           },
"marking_review_sample":
{ Args: { "p_count"?: number,"p_exam": string,"p_marker": string }; Returns: Json
                           },
"marking_review_settle":
{ Args: { "p_first_rev": number,"p_marks"?: Json,"p_outcome": string,"p_reason": string,"p_review": string,"p_second_rev": number }; Returns: Json
                           },
"marking_save":
{ Args: { "p_active_seconds"?: number,"p_marking": string,"p_now"?: string,"p_ops": Json,"p_reason"?: string,"p_rev": number }; Returns: Json
                           },
"marking_script_blocked":
{ Args: { "p_now": string,"p_script": string }; Returns: string
                           },
"marking_script_busy":
{ Args: { "p_script": string }; Returns: boolean
                           },
"marking_script_hand_back":
{ Args: { "p_reason"?: string,"p_script": string }; Returns: Json
                           },
"marking_script_hold":
{ Args: { "p_alert_kind": string,"p_hold_reason": string,"p_page": string,"p_script": string }; Returns: undefined
                           },
"marking_script_lock":
{ Args: { "p_script": string }; Returns: undefined
                           },
"marking_script_pages":
{ Args: { "p_script": string }; Returns: {
              "copy_page": number,"extra": boolean,"marking_path": string,"n": number,"page_id": string,"rotation": number
            }[]
                           },
"marking_script_state":
{ Args: { "p_script": string }; Returns: undefined
                           },
"marking_script_take_back":
{ Args: { "p_reason": string,"p_script": string }; Returns: Json
                           },
"marking_script_take_back_as":
{ Args: { "p_actor": string,"p_reason": string,"p_script": string }; Returns: undefined
                           },
"marking_script_waiting":
{ Args: { "p_now": string,"p_script": string }; Returns: string
                           },
"marking_scripts_pages":
{ Args: { "p_scripts": (string)[] }; Returns: {
              "copy_page": number,"extra": boolean,"marking_path": string,"n": number,"page_id": string,"rotation": number,"script_id": string
            }[]
                           },
"marking_second_add":
{ Args: { "p_reason": string,"p_units": (string)[] }; Returns: Json
                           },
"marking_second_drop":
{ Args: { "p_reason": string,"p_units": (string)[] }; Returns: Json
                           },
"marking_second_release":
{ Args: { "p_reason": string,"p_unit": string }; Returns: undefined
                           },
"marking_second_stuck":
{ Args: { "p_exam": string }; Returns: {
              "unit_id": string
            }[]
                           },
"marking_send_back":
{ Args: { "p_note": string,"p_reason": string,"p_to": string,"p_unit": string }; Returns: Json
                           },
"marking_set_total":
{ Args: { "p_set": Json,"p_unit": string }; Returns: number
                           },
"marking_settings_set":
{ Args: { "p_deadline": string,"p_exam": string,"p_mode": Database["public"]['Enums']["marking_mode"],"p_reason"?: string }; Returns: Json
                           },
"marking_standard_compare":
{ Args: { "p_marking": string }; Returns: Json
                           },
"marking_standard_end":
{ Args: { "p_actor": string,"p_reason": string,"p_standard": string }; Returns: boolean
                           },
"marking_standard_retire":
{ Args: { "p_reason": string,"p_standard": string }; Returns: Json
                           },
"marking_standard_set":
{ Args: { "p_note"?: string,"p_unit": string,"p_use": string }; Returns: Json
                           },
"marking_standards_list":
{ Args: { "p_exam": string }; Returns: Json
                           },
"marking_subject_has_lead":
{ Args: { "p_subject": number }; Returns: boolean
                           },
"marking_subject_markers":
{ Args: { "p_subject": number }; Returns: number
                           },
"marking_submit":
{ Args: { "p_marking": string,"p_now"?: string,"p_rev": number }; Returns: Json
                           },
"marking_take_back":
{ Args: { "p_kind"?: Database["public"]['Enums']["marking_kind"],"p_reason": string,"p_units": (string)[] }; Returns: Json
                           },
"marking_tick":
{ Args: Record<PropertyKey, never>; Returns: undefined
                           },
"marking_tolerance":
{ Args: { "p_max": number,"p_percent": number }; Returns: number
                           },
"marking_total":
{ Args: { "p_marking": string }; Returns: number
                           },
"marking_unit_blocked":
{ Args: { "p_kind"?: Database["public"]['Enums']["marking_kind"],"p_marker": string,"p_next": boolean,"p_now": string,"p_unit": string }; Returns: string
                           },
"marking_unit_max_total":
{ Args: { "p_unit": string }; Returns: number
                           },
"marking_unit_open":
{ Args: { "p_now"?: string,"p_unit": string }; Returns: Json
                           },
"marking_unit_questions":
{ Args: { "p_unit": string }; Returns: {
              "label": string,"leaf": boolean,"mark_step": number,"max_mark": number,"parent_id": string,"path": (number)[],"question_id": string,"top_id": string
            }[]
                           },
"marking_unit_settled":
{ Args: { "p_unit": string }; Returns: boolean
                           },
"marking_unit_take":
{ Args: { "p_by": string,"p_hold_until": string,"p_how": string,"p_kind"?: Database["public"]['Enums']["marking_kind"],"p_marker": string,"p_unit": string }; Returns: undefined
                           },
"marking_unit_take_back":
{ Args: { "p_kind"?: Database["public"]['Enums']["marking_kind"],"p_unit": string }; Returns: boolean
                           },
"marking_units_allowed":
{ Args: { "p_exam": string,"p_kind": Database["public"]['Enums']["marking_kind"],"p_marker": string,"p_next": boolean,"p_unit"?: string }; Returns: {
              "group_id": string,"script_id": string,"unit_id": string
            }[]
                           },
"marking_units_candidates":
{ Args: { "p_exam": string,"p_group": string,"p_marker": string }; Returns: {
              "group_id": string,"script_id": string,"unit_id": string
            }[]
                           },
"marking_units_free":
{ Args: { "p_exam": string,"p_group": string,"p_marker": string,"p_now": string }; Returns: {
              "group_id": string,"unit_id": string
            }[]
                           },
"marking_units_list":
{ Args: { "p_exam": string,"p_marker"?: string,"p_state"?: string }; Returns: Json
                           },
"marking_units_lock":
{ Args: { "p_units": (string)[] }; Returns: undefined
                           },
"marking_units_offered":
{ Args: { "p_exam": string,"p_group": string,"p_kinds": (Database["public"]['Enums']["marking_kind"])[],"p_marker": string }; Returns: {
              "group_id": string,"kind": Database["public"]['Enums']["marking_kind"],"script_id": string,"unit_id": string
            }[]
                           },
"marking_units_pick":
{ Args: { "p_count": number,"p_exam": string,"p_group": string,"p_kinds"?: (Database["public"]['Enums']["marking_kind"])[],"p_marker": string,"p_now": string }; Returns: {
              "kind": Database["public"]['Enums']["marking_kind"],"unit_id": string
            }[]
                           },
"marking_units_refresh":
{ Args: { "p_script": string }; Returns: number
                           },
"marking_work_blocked":
{ Args: { "p_now": string,"p_unit": string,"p_user": string }; Returns: string
                           },
"money_totals":
{ Args: { "p_from": string,"p_to": string }; Returns: Json
                           },
"my_role":
{ Args: Record<PropertyKey, never>; Returns: Database["public"]['Enums']["app_role"]
                           },
"my_status":
{ Args: Record<PropertyKey, never>; Returns: Database["public"]['Enums']["account_status"]
                           },
"normalise_index":
{ Args: { "p_raw": string }; Returns: string
                           },
"paper_access_code":
{ Args: { "p_actor": string,"p_booking": Omit<Database["public"]['Tables']["bookings"]['Row'], Database["public"]['Tables']["bookings"]['ComputedFields']>,"p_exam": Omit<Database["public"]['Tables']["exams"]['Row'], Database["public"]['Tables']["exams"]['ComputedFields']>,"p_kind": Database["public"]['Enums']["paper_download_kind"],"p_now": string }; Returns: string
                           },
"paper_clock":
{ Args: { "p_now": string }; Returns: string
                           },
"paper_copy_issue":
{ Args: { "p_booking": string,"p_kind": Database["public"]['Enums']["paper_download_kind"],"p_now"?: string }; Returns: Json
                           },
"paper_corrected_due":
{ Args: { "p_now"?: string }; Returns: {
              "exam_id": string,"paper": string,"paper_ids": (string)[],"title": string
            }[]
                           },
"paper_corrected_recipients":
{ Args: { "p_paper_ids": (string)[] }; Returns: {
              "email": string,"first_name": string,"profile_id": string
            }[]
                           },
"paper_download_log":
{ Args: { "p_copy": string,"p_kind": Database["public"]['Enums']["paper_download_kind"] }; Returns: Json
                           },
"paper_exam_title":
{ Args: { "p_paper": string,"p_title": string }; Returns: string
                           },
"paper_hold":
{ Args: { "p_exam": string,"p_reason": string }; Returns: Json
                           },
"paper_home_downloads_last_hour":
{ Args: { "p_booking": string,"p_now": string }; Returns: number
                           },
"paper_insert_issue":
{ Args: { "p_booking": string,"p_insert": string,"p_now"?: string }; Returns: Json
                           },
"paper_lookup_codes":
{ Args: { "p_items": Json }; Returns: Json
                           },
"paper_notice_finish":
{ Args: { "p_failed": number,"p_notice": number,"p_now"?: string,"p_sent": number }; Returns: string
                           },
"paper_notice_mark":
{ Args: { "p_notice": number,"p_now"?: string,"p_profile": string }; Returns: string
                           },
"paper_notice_next":
{ Args: { "p_exclude"?: (number)[],"p_now"?: string }; Returns: {
              "exam_id": string,"kind": string,"notice_id": number,"paper": string,"title": string
            }[]
                           },
"paper_notice_open":
{ Args: { "p_now"?: string }; Returns: number
                           },
"paper_notice_recipients":
{ Args: { "p_notice": number }; Returns: {
              "email": string,"first_name": string,"profile_id": string
            }[]
                           },
"paper_notice_unmark":
{ Args: { "p_notice": number,"p_profile": string }; Returns: undefined
                           },
"paper_page_layout":
{ Args: { "p_paper": string }; Returns: Json
                           },
"paper_release_at":
{ Args: { "p_exam": string }; Returns: string
                           },
"paper_release_due":
{ Args: { "p_now"?: string }; Returns: {
              "exam_id": string,"paper": string,"title": string
            }[]
                           },
"paper_release_notify_tick":
{ Args: Record<PropertyKey, never>; Returns: undefined
                           },
"paper_release_now":
{ Args: { "p_exam": string,"p_reason": string }; Returns: Json
                           },
"paper_release_recipients":
{ Args: { "p_exam": string }; Returns: {
              "email": string,"first_name": string,"profile_id": string
            }[]
                           },
"paper_resume":
{ Args: { "p_exam": string,"p_reason": string }; Returns: Json
                           },
"paper_window_code":
{ Args: { "p_exam": Omit<Database["public"]['Tables']["exams"]['Row'], Database["public"]['Tables']["exams"]['ComputedFields']>,"p_now": string }; Returns: string
                           },
"processing_job_claim":
{ Args: { "p_now"?: string,"p_worker": string }; Returns: Json
                           },
"processing_job_fail":
{ Args: { "p_error": string,"p_job": Omit<Database["public"]['Tables']["processing_jobs"]['Row'], Database["public"]['Tables']["processing_jobs"]['ComputedFields']>,"p_now": string }; Returns: undefined
                           },
"processing_job_finish":
{ Args: { "p_attempt": number,"p_error"?: string,"p_job": number,"p_now"?: string,"p_ok": boolean,"p_worker": string }; Returns: Json
                           },
"processing_job_heartbeat":
{ Args: { "p_attempt": number,"p_job": number,"p_now"?: string,"p_worker": string }; Returns: boolean
                           },
"purge_student_residue":
{ Args: { "p_user": string }; Returns: undefined
                           },
"register_child_tx":
{ Args: { "p_child": string,"p_parent": string }; Returns: boolean
                           },
"register_exam_paper":
{ Args: { "p_byte_size": number,"p_exam": string,"p_kind": Database["public"]['Enums']["paper_kind"],"p_page_count": number,"p_reason": string,"p_storage_path": string,"p_title": string }; Returns: Json
                           },
"reject_student_tx":
{ Args: { "p_actor": string,"p_student": string }; Returns: string
                           },
"remove_exam_insert":
{ Args: { "p_paper": string,"p_reason": string }; Returns: Json
                           },
"remove_staff_tx":
{ Args: { "p_actor": string,"p_target": string }; Returns: string
                           },
"replace_unconfirmed_signup":
{ Args: { "p_email": string }; Returns: string
                           },
"request_cancellation":
{ Args: { "p_booking": string }; Returns: Json
                           },
"request_cancellation_as":
{ Args: { "p_actor": string,"p_booking": string,"p_now": string }; Returns: Json
                           },
"request_parent_link_tx":
{ Args: { "p_dob": string,"p_index": string,"p_parent": string }; Returns: boolean
                           },
"save_exam":
{ Args: { "p_booking_deadline": string,"p_centres": Json,"p_duration_minutes": number,"p_format": Database["public"]['Enums']["exam_format"],"p_id": string,"p_paper": string,"p_price_pence": number,"p_starts_at": string,"p_subject_id": number,"p_title": string }; Returns: Json
                           },
"save_venue":
{ Args: { "p_active": boolean,"p_id": string,"p_name": string,"p_rooms": (string)[] }; Returns: Json
                           },
"scan_batch_create":
{ Args: { "p_centre": string,"p_exam": string,"p_manifest_number"?: string }; Returns: Json
                           },
"scan_batch_status":
{ Args: { "p_batch": string }; Returns: Json
                           },
"scan_batch_submit":
{ Args: { "p_batch": string }; Returns: Json
                           },
"scan_booking_complete":
{ Args: { "p_booking": string }; Returns: Json
                           },
"scan_centre_complete":
{ Args: { "p_centre": string,"p_exam": string }; Returns: Json
                           },
"scan_upload_begin":
{ Args: { "p_batch": string,"p_bytes": number,"p_mime": string }; Returns: Json
                           },
"scan_upload_max_bytes":
{ Args: Record<PropertyKey, never>; Returns: number
                           },
"scan_upload_type_ok":
{ Args: { "p_mime": string }; Returns: boolean
                           },
"script_booking_json":
{ Args: { "p_booking": string }; Returns: Json
                           },
"script_booking_locked":
{ Args: { "p_booking": string }; Returns: boolean
                           },
"script_bookings_lock":
{ Args: { "p_bookings": (string)[] }; Returns: undefined
                           },
"script_centre_checked":
{ Args: { "p_booking": string }; Returns: boolean
                           },
"script_create":
{ Args: { "p_booking": string,"p_now": string,"p_source": Database["public"]['Enums']["script_source"] }; Returns: {
              "attention_notified_at": string | null,
"booking_id": string,
"complete": boolean,
"created_at": string,
"exam_id": string,
"extras_locked": Json | null,
"id": string,
"late": boolean,
"late_decision": string | null,
"number": string,
"received_at": string | null,
"source": Database["public"]['Enums']["script_source"],
"state": Database["public"]['Enums']["script_state"],
"state_reason": string | null,
"taken_back_at": string | null,
"taken_back_by": string | null,
"taken_back_reason": string | null,
"updated_at": string,
"version": number
            }
                          SetofOptions: {
        from: "*"
        to: "scripts"
        isOneToOne: true
        isSetofReturn: false
      } },
"script_detail":
{ Args: { "p_script": string }; Returns: Json
                           },
"script_discarded_take":
{ Args: { "p_limit": number,"p_now"?: string }; Returns: Json
                           },
"script_evaluate":
{ Args: { "p_script": string }; Returns: undefined
                           },
"script_evaluate_at":
{ Args: { "p_now": string,"p_script": string }; Returns: undefined
                           },
"script_exception_assign":
{ Args: { "p_booking": string,"p_copy_page": number,"p_exception": string,"p_no_name"?: boolean,"p_reason": string,"p_replace"?: boolean }; Returns: Json
                           },
"script_exception_blank":
{ Args: { "p_exception": string,"p_reason": string }; Returns: Json
                           },
"script_exception_candidates":
{ Args: { "p_exam": string,"p_query": string }; Returns: Json
                           },
"script_exception_check_due":
{ Args: { "p_exception": string }; Returns: Json
                           },
"script_exception_close":
{ Args: { "p_action": string,"p_actor": string,"p_id": string,"p_now": string,"p_reason": string,"p_resolution": string }; Returns: undefined
                           },
"script_exception_confirm":
{ Args: { "p_exception": string,"p_no_name"?: boolean,"p_reason"?: string }; Returns: Json
                           },
"script_exception_conflict":
{ Args: { "p_exception": string }; Returns: Json
                           },
"script_exception_dismiss_missing":
{ Args: { "p_exception": string,"p_pages": (number)[],"p_reason": string }; Returns: Json
                           },
"script_exception_json":
{ Args: { "p_exception": string }; Returns: Json
                           },
"script_exception_keep_existing":
{ Args: { "p_exception": string,"p_reason": string }; Returns: Json
                           },
"script_exception_reject":
{ Args: { "p_exception": string,"p_reason": string }; Returns: Json
                           },
"script_exception_seq":
{ Args: { "p_exception": string }; Returns: number
                           },
"script_exceptions_list":
{ Args: { "p_exam"?: string,"p_kind"?: Database["public"]['Enums']["exception_kind"],"p_state"?: string }; Returns: Json
                           },
"script_extra_pages":
{ Args: { "p_script": string }; Returns: {
              "file_position": number,"page_id": string,"placed_after": number,"source_index": number
            }[]
                           },
"script_family_notices_skip":
{ Args: { "p_reason": string }; Returns: Json
                           },
"script_family_notices_waiting":
{ Args: Record<PropertyKey, never>; Returns: Json
                           },
"script_final_marks":
{ Args: { "p_script": string }; Returns: {
              "mark": number,"not_attempted": boolean,"question_id": string,"source": string
            }[]
                           },
"script_final_total":
{ Args: { "p_script": string }; Returns: number
                           },
"script_home_reject":
{ Args: { "p_actor": string,"p_booking": string,"p_now": string,"p_reason": string,"p_subs": (string)[] }; Returns: undefined
                           },
"script_late_decide":
{ Args: { "p_accept": boolean,"p_reason": string,"p_script": string }; Returns: Json
                           },
"script_links":
{ Args: { "p_script": string }; Returns: Json
                           },
"script_links_current":
{ Args: { "p_links": Json,"p_script": string }; Returns: Json
                           },
"script_links_write":
{ Args: { "p_actor": string,"p_links": Json,"p_now": string,"p_reason": string,"p_script": string }; Returns: boolean
                           },
"script_marking_checks_due":
{ Args: { "p_exam"?: string }; Returns: {
              "copy_page": number,"page_id": string,"script_id": string
            }[]
                           },
"script_marking_checks_list":
{ Args: { "p_exam"?: string }; Returns: Json
                           },
"script_notice_content":
{ Args: { "p_notice": Omit<Database["public"]['Tables']["script_notices"]['Row'], Database["public"]['Tables']["script_notices"]['ComputedFields']> }; Returns: Json
                           },
"script_notice_count":
{ Args: { "p_notice": Omit<Database["public"]['Tables']["script_notices"]['Row'], Database["public"]['Tables']["script_notices"]['ComputedFields']> }; Returns: number
                           },
"script_notice_given_up":
{ Args: { "p_now"?: string }; Returns: number
                           },
"script_notice_mark":
{ Args: { "p_id": number,"p_now"?: string,"p_ok": boolean }; Returns: undefined
                           },
"script_notice_next":
{ Args: { "p_limit": number,"p_now"?: string }; Returns: Json
                           },
"script_notice_recipients":
{ Args: { "p_notice": Omit<Database["public"]['Tables']["script_notices"]['Row'], Database["public"]['Tables']["script_notices"]['ComputedFields']> }; Returns: Json
                           },
"script_notice_record":
{ Args: { "p_id": number,"p_profile": string }; Returns: string
                           },
"script_notice_unmark":
{ Args: { "p_id": number,"p_profile": string }; Returns: undefined
                           },
"script_notify_tick":
{ Args: Record<PropertyKey, never>; Returns: undefined
                           },
"script_number_next":
{ Args: { "p_exam": string }; Returns: string
                           },
"script_page_areas_key":
{ Args: { "p_page": string }; Returns: string
                           },
"script_page_binding":
{ Args: { "p_page": string }; Returns: Json
                           },
"script_page_bookings":
{ Args: { "p_page": string }; Returns: (string)[]
                           },
"script_page_confirm_given":
{ Args: { "p_page": string }; Returns: boolean
                           },
"script_page_confirmed":
{ Args: { "p_page": string }; Returns: boolean
                           },
"script_page_copy":
{ Args: { "p_page": string }; Returns: Record<string, unknown>
                           },
"script_page_elsewhere":
{ Args: { "p_page": string,"p_script": string }; Returns: string
                           },
"script_page_is_answer":
{ Args: { "p_copy": string,"p_page": number }; Returns: boolean
                           },
"script_page_json":
{ Args: { "p_page": string }; Returns: Json
                           },
"script_page_lock":
{ Args: { "p_extra": (string)[],"p_page": string }; Returns: (string)[]
                           },
"script_page_locked":
{ Args: { "p_page": string }; Returns: boolean
                           },
"script_page_marking_checked":
{ Args: { "p_marking_path": string,"p_page": string }; Returns: Json
                           },
"script_page_marking_lost":
{ Args: { "p_cleared"?: boolean,"p_extra"?: Json,"p_page": string }; Returns: undefined
                           },
"script_page_marking_made":
{ Args: { "p_page": string }; Returns: undefined
                           },
"script_page_marking_name_shows":
{ Args: { "p_page": string,"p_reason": string }; Returns: Json
                           },
"script_page_needs_marking_check":
{ Args: { "p_page": string }; Returns: boolean
                           },
"script_page_owners":
{ Args: { "p_page": string }; Returns: (string)[]
                           },
"script_page_pictures_updating":
{ Args: { "p_page": string }; Returns: boolean
                           },
"script_page_poor":
{ Args: { "p_answer": boolean,"p_marking": string,"p_quality": Json }; Returns: boolean
                           },
"script_page_refused":
{ Args: { "p_page": string }; Returns: boolean
                           },
"script_page_remask":
{ Args: { "p_page": string }; Returns: undefined
                           },
"script_page_remask_context":
{ Args: { "p_page": string }; Returns: Json
                           },
"script_page_remask_key":
{ Args: { "p_page": string }; Returns: string
                           },
"script_page_remove":
{ Args: { "p_copy_page": number,"p_reason": string,"p_script": string }; Returns: Json
                           },
"script_page_rotate":
{ Args: { "p_page": string,"p_quarter_turns": number,"p_reason": string }; Returns: Json
                           },
"script_page_set_aside":
{ Args: { "p_actor": string,"p_now": string,"p_page": string,"p_reason": string }; Returns: undefined
                           },
"script_page_set_hidden_areas":
{ Args: { "p_areas": Json,"p_page": string,"p_reason": string }; Returns: Json
                           },
"script_page_slot_answer":
{ Args: { "p_page": string }; Returns: boolean
                           },
"script_page_staff_work":
{ Args: { "p_page": string }; Returns: string
                           },
"script_pages_elsewhere":
{ Args: { "p_pages": (string)[],"p_script": string }; Returns: (string)[]
                           },
"script_pages_record":
{ Args: { "p_attempt": number,"p_job": number,"p_now"?: string,"p_pages": Json,"p_sha256": string,"p_worker": string }; Returns: Json
                           },
"script_pages_remasked":
{ Args: { "p_attempt": number,"p_job": number,"p_now"?: string,"p_pages": Json,"p_worker": string }; Returns: Json
                           },
"script_pages_to_check":
{ Args: { "p_script": string }; Returns: {
              "copy_page": number,"page_id": string
            }[]
                           },
"script_pages_valid":
{ Args: { "p_pages": Json,"p_prefix": string }; Returns: boolean
                           },
"script_pictures_unused_take":
{ Args: { "p_limit"?: number,"p_now"?: string }; Returns: Json
                           },
"script_raise_mixed":
{ Args: { "p_script": string,"p_upload": string }; Returns: undefined
                           },
"script_reject_targets":
{ Args: { "p_exception": string }; Returns: (string)[]
                           },
"script_remask_queue":
{ Args: { "p_upload": string }; Returns: boolean
                           },
"script_resolution_lock":
{ Args: { "p_exception": string,"p_extra": (string)[] }; Returns: (string)[]
                           },
"script_resolution_reason":
{ Args: { "p_reason": string }; Returns: string
                           },
"script_resolution_settle":
{ Args: { "p_actor": string,"p_booking": string,"p_reason": string }; Returns: undefined
                           },
"script_shared_links":
{ Args: { "p_script": string }; Returns: number
                           },
"script_slot_copy":
{ Args: { "p_script": string }; Returns: string
                           },
"script_slot_staff_placed":
{ Args: { "p_copy_page": number,"p_page": string,"p_script": string }; Returns: boolean
                           },
"script_slots_dropped":
{ Args: { "p_links": Json,"p_script": string,"p_upload": string,"p_written": Json }; Returns: undefined
                           },
"script_stale_links":
{ Args: { "p_script": string }; Returns: number
                           },
"script_stats_refresh":
{ Args: Record<PropertyKey, never>; Returns: undefined
                           },
"script_upload_begin":
{ Args: { "p_bytes": number,"p_kind": Database["public"]['Enums']["upload_kind"],"p_mime": string,"p_now"?: string,"p_submission": string }; Returns: Json
                           },
"script_upload_bookings":
{ Args: { "p_upload": string }; Returns: (string)[]
                           },
"script_upload_discard":
{ Args: { "p_upload": string }; Returns: Json
                           },
"script_upload_lock":
{ Args: { "p_upload": string }; Returns: (string)[]
                           },
"script_upload_never_handed_in":
{ Args: { "p_now": string,"p_upload": string }; Returns: boolean
                           },
"script_upload_path_allowed":
{ Args: { "p_add": boolean,"p_path": string }; Returns: boolean
                           },
"script_upload_processed":
{ Args: { "p_now": string,"p_upload": string }; Returns: undefined
                           },
"script_upload_purged":
{ Args: { "p_ids": (string)[],"p_now"?: string }; Returns: undefined
                           },
"script_upload_reorder":
{ Args: { "p_submission": string,"p_uploads": (string)[] }; Returns: Json
                           },
"script_upload_reprocess":
{ Args: { "p_reason": string,"p_upload": string }; Returns: Json
                           },
"script_upload_reprocess_refused":
{ Args: { "p_upload": string }; Returns: string
                           },
"script_upload_staff_changes":
{ Args: { "p_placed"?: boolean,"p_upload": string }; Returns: string
                           },
"script_upload_stale_links":
{ Args: { "p_upload": string }; Returns: number
                           },
"script_upload_stored":
{ Args: { "p_upload": string }; Returns: Json
                           },
"script_version_write":
{ Args: { "p_links": Json,"p_now": string,"p_reason": string,"p_script": string,"p_submission": string,"p_upload": string }; Returns: boolean
                           },
"script_void":
{ Args: { "p_reason": string,"p_script": string }; Returns: Json
                           },
"scripts_dashboard":
{ Args: { "p_now"?: string }; Returns: Json
                           },
"scripts_list":
{ Args: { "p_exam"?: string,"p_late"?: boolean,"p_source"?: Database["public"]['Enums']["script_source"],"p_state"?: Database["public"]['Enums']["script_state"] }; Returns: Json
                           },
"set_account_status_tx":
{ Args: { "p_action": string,"p_actor": string,"p_target": string }; Returns: string
                           },
"set_exam_home_rules":
{ Args: { "p_exam": string,"p_materials": string,"p_rules": string }; Returns: Json
                           },
"set_exam_paper_settings":
{ Args: { "p_exam": string,"p_exam_code": string,"p_reason"?: string,"p_release_minutes_before": number,"p_spare_pages": number }; Returns: Json
                           },
"set_exam_status":
{ Args: { "p_id": string,"p_status": Database["public"]['Enums']["exam_status"] }; Returns: Json
                           },
"set_paper_hidden_areas":
{ Args: { "p_areas": Json,"p_paper": string }; Returns: Json
                           },
"set_paper_page_roles":
{ Args: { "p_paper": string,"p_roles": Json }; Returns: Json
                           },
"sitting_access_code":
{ Args: { "p_acting": boolean,"p_actor": string,"p_booking": Omit<Database["public"]['Tables']["bookings"]['Row'], Database["public"]['Tables']["bookings"]['ComputedFields']> }; Returns: string
                           },
"sitting_acknowledge":
{ Args: { "p_booking": string,"p_now"?: string }; Returns: Json
                           },
"sitting_phase":
{ Args: { "p_exam": Omit<Database["public"]['Tables']["exams"]['Row'], Database["public"]['Tables']["exams"]['ComputedFields']>,"p_now": string }; Returns: string
                           },
"structure_can_edit":
{ Args: { "p_exam": string,"p_user": string }; Returns: boolean
                           }
          }
          Enums: {
            "account_status": "unconfirmed"|"pending"|"profile_incomplete"|"active"|"suspended","app_role": "owner"|"admin"|"teacher"|"tutor"|"corrector"|"student"|"parent","attendance_status": "present"|"late"|"absent","booking_status": "awaiting_payment"|"paid"|"cancel_requested"|"refunded"|"part_refunded"|"cancelled"|"expired","exam_format": "in_person"|"online"|"both","exam_status": "draft"|"published"|"cancelled"|"completed","exception_kind": "no_code"|"unknown_code"|"other_exam"|"not_expected"|"duplicate"|"missing_pages"|"uncoded_family_page"|"mixed_versions"|"poor_quality"|"late"|"name_visible"|"processing_failed","job_state": "queued"|"running"|"done"|"failed","marking_kind": "live"|"second"|"seed"|"practice"|"remark","marking_mode": "whole"|"by_question","page_role": "answer"|"cover"|"blank"|"information","page_state": "matched"|"blank"|"duplicate"|"unmatched"|"rejected","paper_download_kind": "home"|"print_pack"|"reprint"|"admin_preview","paper_kind": "paper"|"insert","script_source": "home"|"centre","script_state": "receiving"|"checking"|"needs_attention"|"verified"|"ready_to_mark"|"marking"|"marked"|"checked"|"final"|"withdrawn"|"void","sitting_mode": "centre"|"home","subject_kind": "school"|"entrance","submission_state": "draft"|"checking"|"received"|"needs_attention"|"rejected","upload_kind": "home_photo"|"home_pdf"|"scan_file","upload_state": "pending"|"stored"|"discarded"|"queued"|"processing"|"processed"|"failed"
          }
          CompositeTypes: {
            [_ in never]: never
          }
        }
}

type DatabaseWithoutInternals = Omit<Database, '__InternalSupabase'>

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
  ? (DefaultSchema["Tables"] & DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
      Row: infer R
    }
    ? R
    : never
  : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
  ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
      Insert: infer I
    }
    ? I
    : never
  : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
  ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
      Update: infer U
    }
    ? U
    : never
  : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never
> = DefaultSchemaEnumNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
  ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
  : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never
> = PublicCompositeTypeNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
  ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
  : never

export const Constants = {
  "graphql_public": {
          Enums: {
            
          }
        },"public": {
          Enums: {
            "account_status": ["unconfirmed", "pending", "profile_incomplete", "active", "suspended"],"app_role": ["owner", "admin", "teacher", "tutor", "corrector", "student", "parent"],"attendance_status": ["present", "late", "absent"],"booking_status": ["awaiting_payment", "paid", "cancel_requested", "refunded", "part_refunded", "cancelled", "expired"],"exam_format": ["in_person", "online", "both"],"exam_status": ["draft", "published", "cancelled", "completed"],"exception_kind": ["no_code", "unknown_code", "other_exam", "not_expected", "duplicate", "missing_pages", "uncoded_family_page", "mixed_versions", "poor_quality", "late", "name_visible", "processing_failed"],"job_state": ["queued", "running", "done", "failed"],"marking_kind": ["live", "second", "seed", "practice", "remark"],"marking_mode": ["whole", "by_question"],"page_role": ["answer", "cover", "blank", "information"],"page_state": ["matched", "blank", "duplicate", "unmatched", "rejected"],"paper_download_kind": ["home", "print_pack", "reprint", "admin_preview"],"paper_kind": ["paper", "insert"],"script_source": ["home", "centre"],"script_state": ["receiving", "checking", "needs_attention", "verified", "ready_to_mark", "marking", "marked", "checked", "final", "withdrawn", "void"],"sitting_mode": ["centre", "home"],"subject_kind": ["school", "entrance"],"submission_state": ["draft", "checking", "received", "needs_attention", "rejected"],"upload_kind": ["home_photo", "home_pdf", "scan_file"],"upload_state": ["pending", "stored", "discarded", "queued", "processing", "processed", "failed"]
          }
        }
} as const
