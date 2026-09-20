package com.noop.account

import android.content.Context
import androidx.work.Data
import androidx.work.WorkManager
import com.noop.push.AccountPushJobAdmission
import com.noop.push.SelfHostedPushWorker

/** Periodic work must never resolve its data owner from the account active at execution time. */
object AccountWorkContext {
    fun input(context: AccountStorageContext): Data =
        SelfHostedPushWorker.accountInput(requireNotNull(context.identity.context))

    fun name(base: String, context: AccountStorageContext): String =
        "$base.${context.namespace}.${context.identity.generation}"

    fun tag(context: AccountStorageContext): String = name("account-work", context)

    fun resolve(context: Context, input: Data): AccountStorageContext? {
        val account = AccountStorageContext.capture(context)
        val captured = account.identity.context ?: return null
        return account.takeIf { account.isCurrent() && AccountPushJobAdmission.matches(captured,
            input.getString(AccountPushJobAdmission.NAMESPACE),
            input.getString(AccountPushJobAdmission.GENERATION)) }
    }

    fun cancel(context: AccountStorageContext) {
        WorkManager.getInstance(AccountStorageContext.platform(context)).cancelAllWorkByTag(tag(context))
    }
}
